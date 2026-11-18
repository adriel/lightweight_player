import Foundation
import CoreMedia
import AVFoundation
import MediaExtension
import os

let mkvLog = Logger(subsystem: "com.lwplayer.mkvreader", category: "reader")

@inline(__always) func nsTime(_ ns: Int64) -> CMTime { CMTime(value: ns, timescale: 1_000_000_000) }
@inline(__always) func nanos(_ t: CMTime) -> Int64 { t.convertScale(1_000_000_000, method: .roundHalfAwayFromZero).value }

/// ExtensionKit principal class (EXPrincipalClass in Info.plist).
@objc(MKVFormatReaderFactory)
final class MKVFormatReaderFactory: NSObject, MEFormatReaderExtension {
    override init() { super.init() }

    func formatReader(with primaryByteSource: MEByteSource, options: MEFormatReaderInstantiationOptions?) throws -> any MEFormatReader {
        do {
            let file = try MatroskaFile(reader: MEByteSourceReader(primaryByteSource))
            mkvLog.info("opened \(primaryByteSource.fileName, privacy: .public): \(file.tracks.count) tracks")
            return MKVFormatReader(source: primaryByteSource, file: file)
        } catch {
            mkvLog.error("open failed: \(String(describing: error), privacy: .public)")
            throw MEError(.parsingFailure)
        }
    }
}

/// Synchronous reads through the byte source the system hands us (works for local files and network URLs).
final class MEByteSourceReader: MKVByteReader {
    let source: MEByteSource
    init(_ s: MEByteSource) { source = s }
    var length: Int64 { source.fileLength }
    func read(_ offset: Int64, _ count: Int) throws -> Data {
        let n = Int(max(0, min(Int64(count), length - offset)))
        guard n > 0 else { return Data() }
        var d = Data(count: n)
        var got = 0
        var err: NSError?
        let ok = d.withUnsafeMutableBytes { MEByteSourceReadSync(source, offset, n, $0.baseAddress!, &got, &err) }
        if !ok && got == 0 { throw err ?? MEError(.endOfStream) }
        if got < n { d.removeSubrange(got...) }
        return d
    }
}

final class MKVFormatReader: NSObject, MEFormatReader {
    let source: MEByteSource
    let file: MatroskaFile

    init(source: MEByteSource, file: MatroskaFile) {
        self.source = source; self.file = file
    }

    func loadFileInfo(completionHandler: @escaping @Sendable (MEFileInfo?, (any Error)?) -> Void) {
        let info = MEFileInfo()
        info.duration = nsTime(file.durationNs)
        completionHandler(info, nil)
    }

    func loadMetadata(completionHandler: @escaping @Sendable ([AVMetadataItem]?, (any Error)?) -> Void) {
        var items: [AVMetadataItem] = []
        if let title = file.title {
            let m = AVMutableMetadataItem()
            m.identifier = .commonIdentifierTitle
            m.value = title as NSString
            items.append(m)
        }
        completionHandler(items, nil)
    }

    func loadTrackReaders(completionHandler: @escaping @Sendable ([any METrackReader]?, (any Error)?) -> Void) {
        var readers: [any METrackReader] = []
        var enabledVideo = false, enabledAudio = false
        // Prefer the default-flagged track of each type; fall back to the first one.
        let ordered = file.tracks.filter(\.isDefault) + file.tracks.filter { !$0.isDefault }
        var enable: Set<UInt64> = []
        for t in ordered {
            if t.isVideo, !enabledVideo, MKVFormats.formatDescription(for: t) != nil { enable.insert(t.number); enabledVideo = true }
            if t.isAudio, !enabledAudio, MKVFormats.formatDescription(for: t) != nil { enable.insert(t.number); enabledAudio = true }
        }
        for t in file.tracks where t.isVideo || t.isAudio {
            guard let fd = MKVFormats.formatDescription(for: t) else {
                mkvLog.info("skipping unsupported track \(t.number) \(t.codecID, privacy: .public)")
                continue
            }
            readers.append(MKVTrackReader(owner: self, track: t, format: fd, enabled: enable.contains(t.number)))
        }
        completionHandler(readers, nil)
    }
}

final class MKVTrackReader: NSObject, METrackReader {
    let owner: MKVFormatReader
    let track: MKVTrack
    let format: CMFormatDescription
    let enabled: Bool
    var file: MatroskaFile { owner.file }

    init(owner: MKVFormatReader, track: MKVTrack, format: CMFormatDescription, enabled: Bool) {
        self.owner = owner; self.track = track; self.format = format; self.enabled = enabled
    }

    func loadTrackInfo(completionHandler: @escaping @Sendable (METrackInfo?, (any Error)?) -> Void) {
        let info = METrackInfo(__mediaType: track.isVideo ? kCMMediaType_Video : kCMMediaType_Audio,
                               trackID: CMPersistentTrackID(track.number), formatDescriptions: [format])
        info.isEnabled = enabled
        info.naturalTimescale = CMTimeScale(clamping: max(1, 1_000_000_000 / max(file.timestampScale, 1)))
        if let bcp = track.languageBCP47 { info.extendedLanguageTag = bcp }
        else if track.language != "und", let code = Locale.Language(identifier: track.language).languageCode?.identifier(.alpha2) {
            info.extendedLanguageTag = code
        }
        if track.isVideo {
            let w = track.displayWidth > 0 ? track.displayWidth : track.width
            let h = track.displayHeight > 0 ? track.displayHeight : track.height
            info.naturalSize = CGSize(width: w, height: h)
            if track.defaultDurationNs > 0 { info.nominalFrameRate = Float32(1e9 / Double(track.defaultDurationNs)) }
            info.requiresFrameReordering = track.mayReorder
        }
        completionHandler(info, nil)
    }

    private func cursor(_ make: () throws -> MKVPosition, _ completion: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void) {
        do { completion(try MKVSampleCursor(reader: self, position: make()), nil) }
        catch { mkvLog.error("cursor: \(String(describing: error), privacy: .public)"); completion(nil, MEError(.noSamples)) }
    }

    func generateSampleCursor(atPresentationTimeStamp presentationTimeStamp: CMTime, completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void) {
        cursor({ try file.position(track.number, atPTS: nanos(presentationTimeStamp)) }, completionHandler)
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void) {
        cursor({ try file.firstPosition(track.number) }, completionHandler)
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void) {
        cursor({ try file.lastPosition(track.number) }, completionHandler)
    }

    func loadUneditedDuration(completionHandler: @escaping @Sendable (CMTime, (any Error)?) -> Void) {
        completionHandler(nsTime(file.durationNs), nil)
    }
}

final class MKVSampleCursor: NSObject, MESampleCursor {
    let reader: MKVTrackReader
    private(set) var position: MKVPosition
    private(set) var sample: MKVSample
    private var file: MatroskaFile { reader.file }
    private var trackNo: UInt64 { reader.track.number }

    init(reader: MKVTrackReader, position: MKVPosition, sample: MKVSample? = nil) throws {
        self.reader = reader
        self.position = position
        self.sample = try sample ?? reader.file.sample(reader.track.number, position)
    }

    func copy(with zone: NSZone? = nil) -> Any {
        try! MKVSampleCursor(reader: reader, position: position, sample: sample)
    }

    private func move(to p: MKVPosition) throws {
        sample = try file.sample(trackNo, p)
        position = p
    }

    var presentationTimeStamp: CMTime { nsTime(sample.ptsNs) }
    var decodeTimeStamp: CMTime { nsTime(sample.dtsNs) }
    var currentSampleDuration: CMTime { sample.durationNs > 0 ? nsTime(sample.durationNs) : .indefinite }
    var currentSampleFormatDescription: CMFormatDescription? { reader.format }

    func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {
        do {
            let (p, n) = try file.step(trackNo, from: position, by: stepCount)
            try move(to: p)
            completionHandler(n, nil)
        } catch { completionHandler(0, error) }
    }

    func stepInPresentationOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {
        do {
            let (p, n) = try reader.track.mayReorder ? file.stepPresentation(trackNo, from: position, by: stepCount)
                                                     : file.step(trackNo, from: position, by: stepCount)
            try move(to: p)
            completionHandler(n, nil)
        } catch { completionHandler(0, error) }
    }

    func stepByDecodeTime(_ deltaDecodeTime: CMTime, completionHandler: @escaping @Sendable (CMTime, Bool, (any Error)?) -> Void) {
        do {
            let pinned = try stepToTime(nanos(deltaDecodeTime), usingDecodeTime: true)
            completionHandler(decodeTimeStamp, pinned, nil)
        } catch { completionHandler(decodeTimeStamp, true, error) }
    }

    func stepByPresentationTime(_ deltaPresentationTime: CMTime, completionHandler: @escaping @Sendable (CMTime, Bool, (any Error)?) -> Void) {
        do {
            let pinned = try stepToTime(nanos(deltaPresentationTime), usingDecodeTime: false)
            completionHandler(presentationTimeStamp, pinned, nil)
        } catch { completionHandler(presentationTimeStamp, true, error) }
    }

    /// Moves to the sample whose time range contains (current + delta). Returns true if pinned at either end.
    private func stepToTime(_ delta: Int64, usingDecodeTime: Bool) throws -> Bool {
        func t(_ s: MKVSample) -> Int64 { usingDecodeTime ? s.dtsNs : s.ptsNs }
        let target = t(sample) + delta
        // Large jumps: use the cluster index, then refine sample by sample.
        if abs(delta) > 2_000_000_000 {
            try move(to: try file.position(trackNo, atPTS: target))
        }
        if target >= t(sample) {
            while true {
                if target < t(sample) + max(sample.durationNs, 1) { return false }
                let (p, n) = try file.step(trackNo, from: position, by: 1)
                if n == 0 { return true }
                let next = try file.sample(trackNo, p)
                if t(next) > target { return false }
                position = p; sample = next
            }
        } else {
            while t(sample) > target {
                let (p, n) = try file.step(trackNo, from: position, by: -1)
                if n == 0 { return true }
                try move(to: p)
            }
            return false
        }
    }

    var syncInfo: AVSampleCursorSyncInfo {
        AVSampleCursorSyncInfo(sampleIsFullSync: ObjCBool(sample.isKey), sampleIsPartialSync: false, sampleIsDroppable: ObjCBool(sample.isDiscardable))
    }

    var dependencyInfo: AVSampleCursorDependencyInfo {
        AVSampleCursorDependencyInfo(sampleIndicatesWhetherItHasDependentSamples: false, sampleHasDependentSamples: false,
                                     sampleIndicatesWhetherItDependsOnOthers: true, sampleDependsOnOthers: ObjCBool(!sample.isKey),
                                     sampleIndicatesWhetherItHasRedundantCoding: false, sampleHasRedundantCoding: false)
    }

    func samplesWithEarlierDTSsMayHaveLaterPTSs(than cursor: any MESampleCursor) -> Bool {
        guard reader.track.mayReorder, let o = cursor as? MKVSampleCursor else { return false }
        return sample.dtsNs + 2 * max(reader.track.reorderDelayNs, 0) >= o.sample.ptsNs
    }

    func samplesWithLaterDTSsMayHaveEarlierPTSs(than cursor: any MESampleCursor) -> Bool {
        guard reader.track.mayReorder, let o = cursor as? MKVSampleCursor else { return false }
        return sample.dtsNs < o.sample.ptsNs
    }

    var decodeTimeOfLastSampleReachableByForwardSteppingThatIsAlreadyLoadedByByteSource: CMTime {
        let src = reader.owner.source
        let avail = src.availableLength(at: sample.offset)
        if avail >= src.fileLength - sample.offset { return nsTime(max(file.durationNs, sample.dtsNs)) }
        let bps = file.estimatedBytesPerSecond
        guard bps > 0 else { return decodeTimeStamp }
        return nsTime(sample.dtsNs + Int64(Double(max(avail, 0)) / bps * 1e9))
    }

    func sampleLocation() throws -> MESampleLocation {
        guard reader.track.strippedHeader == nil else { throw MEError(.locationNotAvailable) }
        return MESampleLocation(byteSource: reader.owner.source,
                                sampleLocation: AVSampleCursorStorageRange(offset: sample.offset, length: Int64(sample.size)))
    }

    /// Only used for header-stripped tracks (sample bytes must be re-assembled).
    func loadSampleBufferContainingSamples(to endSampleCursor: (any MESampleCursor)?, completionHandler: @escaping @Sendable (CMSampleBuffer?, (any Error)?) -> Void) {
        do {
            let data = try file.readSample(sample, track: reader.track)
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
                                               offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard let block else { throw MEError(.allocationFailure) }
            data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
            var sb: CMSampleBuffer?
            if reader.track.isAudio {
                var desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: reader.format, sampleCount: 1,
                                                                     presentationTimeStamp: presentationTimeStamp, packetDescriptions: &desc, sampleBufferOut: &sb)
            } else {
                var timing = CMSampleTimingInfo(duration: currentSampleDuration, presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: decodeTimeStamp)
                var size = data.count
                CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: reader.format, sampleCount: 1, sampleTimingEntryCount: 1,
                                          sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
            }
            completionHandler(sb, sb == nil ? MEError(.allocationFailure) : nil)
        } catch { completionHandler(nil, error) }
    }
}
