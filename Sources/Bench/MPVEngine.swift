import AppKit
import OpenGL.GL3
import CMPV

/// Engine D: libmpv with hwdec=videotoolbox, rendered through mpv's OpenGL render API into a
/// CAOpenGLLayer (the same approach IINA uses). VideoToolbox frames reach GL as IOSurfaces (zero-copy).
final class MPVEngine: PlayerEngine {
    let kind = EngineKind.mpv
    let view: NSView
    var onEvent: ((EngineEvent) -> Void)?
    private(set) var warnings: [EngineWarning] = []
    let mpv: OpaquePointer
    private let glLayer: MPVGLLayer
    private let eventQueue = DispatchQueue(label: "engine.d.events")
    private var _volume: Float = 1

    init() {
        let mpv = mpv_create()!
        self.mpv = mpv
        func set(_ k: String, _ v: String) { mpv_set_option_string(mpv, k, v) }
        set("vo", "libmpv")
        set("hwdec", "videotoolbox")
        set("terminal", "no")
        set("input-default-bindings", "no")
        set("input-vo-keyboard", "no")
        set("osc", "no")
        set("keep-open", "yes")
        set("sub-auto", "no")
        set("subs-fallback-forced", "always")
        set("sid", "auto")
        // Disk-backed cache: keep RAM small, put read-ahead on disk.
        set("cache", "yes")
        set("cache-on-disk", "yes")
        set("demuxer-max-bytes", "32MiB")
        set("demuxer-max-back-bytes", "8MiB")
        set("demuxer-readahead-secs", "600")
        set("cache-secs", "600")
        mpv_initialize(mpv)
        glLayer = MPVGLLayer(mpv: mpv)
        view = LayerHostView(hosted: glLayer)
        mpv_observe_property(mpv, 0, "hwdec-current", MPV_FORMAT_STRING)
        mpv_set_wakeup_callback(mpv, { ctx in
            let engine = Unmanaged<MPVEngine>.fromOpaque(ctx!).takeUnretainedValue()
            engine.eventQueue.async { engine.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func drainEvents() {
        while true {
            guard let ev = mpv_wait_event(mpv, 0) else { return }
            switch ev.pointee.event_id {
            case MPV_EVENT_NONE: return
            case MPV_EVENT_FILE_LOADED: DispatchQueue.main.async { self.onEvent?(.ready) }
            case MPV_EVENT_PLAYBACK_RESTART:
                DispatchQueue.main.async { self.onEvent?(.firstFrame) }
            case MPV_EVENT_END_FILE:
                let reason = ev.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if reason?.reason == MPV_END_FILE_REASON_ERROR {
                    DispatchQueue.main.async { self.onEvent?(.failed("mpv error \(reason?.error ?? 0)")) }
                } else { DispatchQueue.main.async { self.onEvent?(.ended) } }
            case MPV_EVENT_SHUTDOWN: return
            default: break
            }
        }
    }

    private func getDouble(_ name: String) -> Double {
        var v = 0.0
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
        return v
    }
    private func getString(_ name: String) -> String {
        guard let c = mpv_get_property_string(mpv, name) else { return "-" }
        defer { mpv_free(c) }
        return String(cString: c)
    }
    private func command(_ args: [String]) {
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        mpv_command_async(mpv, 0, &cargs)
        cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) }
    }

    var currentTime: Double { getDouble("time-pos") }
    var duration: Double { getDouble("duration") }
    var isPlaying: Bool { getString("pause") == "no" }
    var volume: Float {
        get { _volume }
        set { _volume = newValue; var v = Double(newValue * 100); mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &v) }
    }

    func open(_ url: URL) { command(["loadfile", url.isFileURL ? url.path : url.absoluteString]) }
    func play() { mpv_set_property_string(mpv, "pause", "no") }
    func pause() { mpv_set_property_string(mpv, "pause", "yes") }
    func seek(to seconds: Double, accurate: Bool) {
        command(["seek", String(seconds), accurate ? "absolute+exact" : "absolute+keyframes"])
    }
    func close() {
        glLayer.shutdown()
        mpv_set_wakeup_callback(mpv, nil, nil)
        mpv_terminate_destroy(mpv)
    }
    func diagnostics() -> [String: String] {
        ["hwdec": getString("hwdec-current"), "video": getString("video-codec"), "audio": getString("audio-codec-name"),
         "droppedFrames": getString("frame-drop-count")]
    }
}

/// CAOpenGLLayer that asks mpv to render into the layer's FBO whenever mpv signals a new frame.
final class MPVGLLayer: CAOpenGLLayer {
    private let mpv: OpaquePointer
    private var renderCtx: OpaquePointer?
    private let renderQueue = DispatchQueue(label: "engine.d.render")
    private var needsFlip = true
    private var cglPixelFormat: CGLPixelFormatObj?
    private var cglContext: CGLContextObj?

    init(mpv: OpaquePointer) {
        self.mpv = mpv
        super.init()
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        // Render at backing scale for sharpness; mpv scales on the GPU.
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
            kCGLPFAColorSize, CGLPixelFormatAttribute(32), CGLPixelFormatAttribute(0)
        ]
        var npix: GLint = 0
        CGLChoosePixelFormat(attrs, &cglPixelFormat, &npix)
        CGLCreateContext(cglPixelFormat!, nil, &cglContext)
        CGLSetCurrentContext(cglContext)
        createRenderContext()
    }
    override init(layer: Any) {
        let other = layer as! MPVGLLayer
        mpv = other.mpv
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func createRenderContext() {
        var glInit = mpv_opengl_init_params(get_proc_address: { _, name in
            let sym = CFStringCreateWithCString(nil, name, CFStringBuiltInEncodings.ASCII.rawValue)
            let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
            return CFBundleGetFunctionPointerForName(bundle, sym)
        }, get_proc_address_ctx: nil)
        let api = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(api) }
        withUnsafeMutablePointer(to: &glInit) { initPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                mpv_render_param()
            ]
            mpv_render_context_create(&renderCtx, mpv, &params)
        }
        mpv_render_context_set_update_callback(renderCtx, { ctx in
            let layer = Unmanaged<MPVGLLayer>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { layer.setNeedsDisplay() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func shutdown() {
        guard let renderCtx else { return }
        mpv_render_context_set_update_callback(renderCtx, nil, nil)
        mpv_render_context_free(renderCtx)
        self.renderCtx = nil
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj { cglPixelFormat! }
    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj { cglContext! }
    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        renderCtx != nil
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        guard let renderCtx else { return }
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        var data = mpv_opengl_fbo(fbo: Int32(fbo), w: viewport[2], h: viewport[3], internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &data) { dp in
            withUnsafeMutablePointer(to: &flip) { fp in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(dp)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(fp)),
                    mpv_render_param()
                ]
                mpv_render_context_render(renderCtx, &params)
            }
        }
        glFlush()
    }
}

func makeEngine(_ kind: EngineKind) -> PlayerEngine {
    switch kind {
    case .avplayer: AVPlayerEngine(useMediaExtensions: false)
    case .avplayerExt: AVPlayerEngine(useMediaExtensions: true)
    case .sampleBuffer: SampleBufferEngine()
    case .mpv: MPVEngine()
    }
}

private let sharedEmptyCues = CueStore()
extension MPVEngine { var cues: CueStore { sharedEmptyCues } }
