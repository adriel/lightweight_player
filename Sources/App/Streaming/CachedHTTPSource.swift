import Foundation

/// Random-access HTTP(S) byte source backed by a sparse temp file on disk.
///
/// - The demuxer reads through `read(_:count:at:)`, which blocks until the bytes are on disk.
/// - A single ranged download runs ahead of the read position until `readAheadBytes` are buffered
///   (default: 10 minutes at the file's average bitrate), then pauses; it resumes when the buffer drains.
/// - Seeking outside the downloaded ranges restarts the download at the new position; ranges already
///   on disk are kept, so seeking back is instant.
/// - RAM use is constant (one small chunk in flight); the buffer lives in the file system cache/disk.
/// - The cache file is unlinked as soon as it's opened: only our descriptor keeps it alive, so its disk
///   space is returned the moment the source closes — or the process exits, even on a crash or force quit.
final class CachedHTTPSource: @unchecked Sendable {
    struct Stats { var length: Int64; var cachedBytes: Int64; var aheadBytes: Int64; var downloading: Bool; var bytesPerSecond: Double }

    let url: URL
    private let authorization: String?
    private let fd: Int32
    private let cond = NSCondition()
    private var ranges = ByteRanges()
    private(set) var length: Int64 = -1
    private var readPos: Int64 = 0
    /// True while a reader is blocked waiting for bytes that aren't downloaded yet (= the player is starving).
    private var waitingReaders = 0
    var isStalled: Bool { cond.withLock { waitingReaders > 0 } }
    /// LP_NET_THROTTLE=<KB/s>: debug bandwidth cap to reproduce buffering.
    private static let throttle = ProcessInfo.processInfo.environment["LP_NET_THROTTLE"].flatMap(Double.init).map { $0 * 1024 }
    private var downloadPos: Int64 = 0
    private var downloadEnd: Int64 = -1          // exclusive end of the current request, -1 = open-ended
    private var task: URLSessionDataTask?
    private var taskGeneration = 0
    private var lastError: Error?
    private var closed = false
    private var session: URLSession!
    private let delegateQueue = OperationQueue()
    private var rateWindow: [(Date, Int)] = []

    /// Bytes to keep buffered ahead of the read position. Updated by the engine once the bitrate is known.
    /// Capped at 3/4 of `maxDiskBytes`, so the read-ahead always fits under the disk cap.
    var readAheadBytes: Int64 {
        get { cond.withLock { _readAhead } }
        set { cond.withLock { _readAhead = max(min(newValue, _maxDisk * 3 / 4), 4 << 20) }; resumeIfNeeded() }
    }
    private var _readAhead: Int64 = 64 << 20
    /// Upper bound on disk used by this stream; data furthest from the playhead is evicted past it.
    var maxDiskBytes: Int64 {
        get { cond.withLock { _maxDisk } }
        set { cond.withLock { _maxDisk = max(newValue, 64 << 20); _readAhead = min(_readAhead, _maxDisk * 3 / 4) } }
    }
    private var _maxDisk: Int64 = 8 << 30
    var timeout: TimeInterval = 30

    /// Open sources, for reporting disk use (their files are unlinked, so a directory listing can't see them).
    private static let live = NSHashTable<CachedHTTPSource>.weakObjects()
    private static let liveLock = NSLock()
    /// Disk currently held by open stream caches in this process.
    static var liveDiskBytes: Int64 {
        liveLock.withLock { live.allObjects }.reduce(0) { $0 + $1.stats.cachedBytes }
    }

    /// Deletes `stream-*.cache` files in `directory`. Files of open sources are unlinked at creation, so anything
    /// still listed is a leftover (from a crash, a force quit or an older build); deleting a file another process
    /// still has open only unlinks it, which doesn't disturb that process.
    static func removeLeftovers(in directory: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for n in names where n.hasPrefix("stream-") && n.hasSuffix(".cache") {
            try? fm.removeItem(at: directory.appendingPathComponent(n))
        }
    }

    init(url: URL, cacheDirectory: URL) throws {
        // Credentials embedded in the URL become a Basic auth header (URLSession won't send them preemptively).
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let user = comps.user {
            let pass = comps.password ?? ""
            authorization = "Basic " + Data("\(user.removingPercentEncoding ?? user):\(pass.removingPercentEncoding ?? pass)".utf8).base64EncodedString()
            comps.user = nil; comps.password = nil
        } else { authorization = nil }
        self.url = comps.url!
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let fileURL = cacheDirectory.appendingPathComponent("stream-\(UUID().uuidString).cache")
        fd = Darwin.open(fileURL.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        // Anonymous from here on: nothing to clean up by name, and the kernel frees it when the fd goes away.
        unlink(fileURL.path)
        // Don't let the page cache treat this as precious; we re-read it once.
        _ = fcntl(fd, F_NOCACHE, 0)
        delegateQueue.maxConcurrentOperationCount = 1
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: cfg, delegate: SessionDelegate(owner: self), delegateQueue: delegateQueue)
        Self.liveLock.withLock { Self.live.add(self) }
    }

    deinit { close() }

    /// Starts the first request and waits for the response headers (to learn the total length).
    func open() throws {
        cond.lock()
        startDownload(from: 0)
        let deadline = Date().addingTimeInterval(timeout)
        while length < 0 && lastError == nil && !closed {
            if !cond.wait(until: deadline) { break }
        }
        let err = lastError, len = length
        cond.unlock()
        if let err { throw err }
        if len < 0 { throw URLError(.timedOut) }
    }

    func close() {
        cond.lock()
        if closed { cond.unlock(); return }
        closed = true
        task?.cancel(); task = nil
        cond.broadcast()
        cond.unlock()
        session?.invalidateAndCancel()
        // The file is already unlinked: closing the last descriptor releases its disk space.
        cond.withLock {
            ranges = ByteRanges()
            Darwin.close(fd)
        }
    }

    /// Blocking read. Returns bytes read, 0 at EOF, -1 on error/close.
    func read(_ buffer: UnsafeMutableRawPointer, count: Int, at offset: Int64) -> Int {
        cond.lock()
        defer { cond.unlock() }
        readPos = offset
        let deadline = Date().addingTimeInterval(timeout)
        while !closed {
            if length >= 0 && offset >= length { return 0 }
            let avail = ranges.contiguous(from: offset)
            if avail > 0 {
                let n = Int(min(Int64(count), avail))
                let r = pread(fd, buffer, n, offset)
                resumeLocked()
                return r
            }
            // Not on disk: make sure a download is heading here.
            if task == nil || downloadPos > offset || offset - downloadPos > 2 << 20 {
                startDownload(from: offset)
            }
            waitingReaders += 1
            let woke = cond.wait(until: deadline)
            waitingReaders -= 1
            if !woke { return -1 }
        }
        return -1
    }

    var stats: Stats {
        cond.withLock {
            let now = Date()
            let recent = rateWindow.filter { now.timeIntervalSince($0.0) < 3 }
            let bps = Double(recent.reduce(0) { $0 + $1.1 }) / 3
            return Stats(length: length, cachedBytes: ranges.total, aheadBytes: ranges.contiguous(from: readPos), downloading: task != nil, bytesPerSecond: bps)
        }
    }

    /// Downloaded spans as fractions of the file, for drawing the buffer indicator on the seek bar.
    func bufferedFractions() -> [ClosedRange<Double>] {
        cond.withLock {
            guard length > 0 else { return [] }
            return ranges.spans.map { Double($0.lowerBound) / Double(length)...Double($0.upperBound) / Double(length) }
        }
    }

    // MARK: Download control (call with cond locked)

    private func startDownload(from offset: Int64) {
        task?.cancel()
        taskGeneration += 1
        // Don't re-download data we already have: begin at the first missing byte, stop at the next cached span.
        let start = offset + ranges.contiguous(from: offset)
        if length >= 0 && start >= length { task = nil; return }
        let end = ranges.nextStart(after: start).map { $0 } ?? -1
        var req = URLRequest(url: url)
        req.setValue(end > 0 ? "bytes=\(start)-\(end - 1)" : "bytes=\(start)-", forHTTPHeaderField: "Range")
        if let authorization { req.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let t = session.dataTask(with: req)
        t.taskDescription = String(taskGeneration)
        downloadPos = start
        downloadEnd = end
        task = t
        lastError = nil
        t.resume()
    }

    private func resumeLocked() {
        guard task == nil, !closed, length > 0 else { return }
        let ahead = ranges.contiguous(from: readPos)
        if readPos + ahead < length && ahead < _readAhead * 9 / 10 {
            startDownload(from: readPos)
        }
    }

    private func resumeIfNeeded() { cond.withLock { resumeLocked() } }

    private func evictIfNeeded() {
        guard ranges.total > _maxDisk else { return }
        let target = _maxDisk * 8 / 10
        // 1. Data behind the playhead, oldest first (keep 64 MB of history, less under a small cap). This includes
        //    the start of the span being played, so a stream watched straight through stays under the cap.
        let keepFrom = max(0, readPos - min(64 << 20, _maxDisk / 8))
        for span in ranges.spans where span.lowerBound < keepFrom {
            let excess = ranges.total - target
            guard excess > 0 else { return }
            drop(span.lowerBound..<min(span.upperBound, keepFrom, span.lowerBound + excess))
        }
        // 2. Spans ahead that the reader isn't on (left over from earlier seeks), furthest first.
        let liveEnd = readPos + ranges.contiguous(from: readPos)
        for span in ranges.spans.reversed() where span.lowerBound > liveEnd {
            guard ranges.total > target else { return }
            drop(span)
        }
    }

    /// Forgets `r` and gives its blocks back to the file system.
    private func drop(_ r: Range<Int64>) {
        ranges.subtract(r)
        // F_PUNCHHOLE needs block-aligned bounds (EINVAL otherwise); align inward to 1 MB, which covers any
        // block size. The partial edges stay on disk but are no longer counted as cached, so they're re-fetched.
        let align: Int64 = 1 << 20
        let start = (r.lowerBound + align - 1) / align * align, end = r.upperBound / align * align
        guard end > start else { return }
        var args = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
        _ = fcntl(fd, F_PUNCHHOLE, &args)
    }

    // MARK: URLSession callbacks (delegate queue)

    fileprivate func didReceive(response: URLResponse, generation: Int) -> URLSession.ResponseDisposition {
        cond.lock(); defer { cond.unlock() }
        guard generation == taskGeneration, let http = response as? HTTPURLResponse else { return .cancel }
        if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range"), let total = cr.split(separator: "/").last, let n = Int64(total) {
            length = n
        } else if http.statusCode == 200 {
            // Server ignored Range: the body starts at 0.
            length = http.expectedContentLength
            downloadPos = 0
        } else {
            lastError = URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            task = nil
            cond.broadcast()
            return .cancel
        }
        cond.broadcast()
        return .allow
    }

    fileprivate func didReceive(data: Data, generation: Int) {
        if let t = Self.throttle {
            // Debug cap: skip stale chunks of cancelled requests first, and never sleep holding the lock.
            guard cond.withLock({ generation == taskGeneration && !closed }) else { return }
            usleep(UInt32(Double(data.count) / t * 1_000_000))
        }
        cond.lock(); defer { cond.unlock() }
        guard generation == taskGeneration, !closed else { return }
        let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, downloadPos) }
        guard written == data.count else { lastError = POSIXError(.EIO); task?.cancel(); task = nil; cond.broadcast(); return }
        ranges.insert(downloadPos..<(downloadPos + Int64(data.count)))
        downloadPos += Int64(data.count)
        rateWindow.append((Date(), data.count))
        if rateWindow.count > 512 { rateWindow.removeFirst(256) }
        cond.broadcast()
        // Pause once enough is buffered ahead of the reader.
        if downloadPos - readPos > _readAhead && readPos <= downloadPos {
            task?.cancel(); task = nil
        }
        evictIfNeeded()
    }

    fileprivate func didComplete(error: Error?, generation: Int) {
        cond.lock(); defer { cond.unlock() }
        guard generation == taskGeneration else { return }
        task = nil
        if let error, (error as? URLError)?.code != .cancelled { lastError = error }
        cond.broadcast()
        // A range request that stopped at a cached span: continue after it if the reader still needs data.
        if lastError == nil { resumeLocked() }
    }

    private final class SessionDelegate: NSObject, URLSessionDataDelegate {
        weak var owner: CachedHTTPSource?
        init(owner: CachedHTTPSource) { self.owner = owner }
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
            owner?.didReceive(response: response, generation: Int(dataTask.taskDescription ?? "") ?? -1) ?? .cancel
        }
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.didReceive(data: data, generation: Int(dataTask.taskDescription ?? "") ?? -1)
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.didComplete(error: error, generation: Int(task.taskDescription ?? "") ?? -1)
        }
    }
}

/// Sorted, merged set of half-open byte ranges.
struct ByteRanges {
    private(set) var spans: [Range<Int64>] = []
    var total: Int64 { spans.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    mutating func insert(_ r: Range<Int64>) {
        guard !r.isEmpty else { return }
        var lo = r.lowerBound, hi = r.upperBound
        var out: [Range<Int64>] = []
        var placed = false
        for s in spans {
            if s.upperBound < lo { out.append(s) }
            else if s.lowerBound > hi {
                if !placed { out.append(lo..<hi); placed = true }
                out.append(s)
            } else { lo = min(lo, s.lowerBound); hi = max(hi, s.upperBound) }
        }
        if !placed { out.append(lo..<hi) }
        spans = out
    }

    /// Removes every byte in `r`, splitting spans that straddle its ends.
    mutating func subtract(_ r: Range<Int64>) {
        guard !r.isEmpty else { return }
        var out: [Range<Int64>] = []
        for s in spans {
            if s.upperBound <= r.lowerBound || s.lowerBound >= r.upperBound { out.append(s); continue }
            if s.lowerBound < r.lowerBound { out.append(s.lowerBound..<r.lowerBound) }
            if s.upperBound > r.upperBound { out.append(r.upperBound..<s.upperBound) }
        }
        spans = out
    }

    /// Bytes available contiguously starting at `offset` (0 if `offset` isn't cached).
    func contiguous(from offset: Int64) -> Int64 {
        for s in spans where s.contains(offset) { return s.upperBound - offset }
        return 0
    }

    /// Start of the first cached span strictly after `offset`.
    func nextStart(after offset: Int64) -> Int64? { spans.first { $0.lowerBound > offset }?.lowerBound }
}
