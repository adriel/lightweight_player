import Foundation
import CryptoKit

/// On-disk store for seek-bar thumbnails: one folder per video (and pixel size), one small JPEG per keyframe,
/// named by the keyframe's time in milliseconds. Nothing is kept in RAM beyond the few images a generator
/// holds; the folder's modification date is its "last used" time for expiry and size trimming.
enum ThumbnailCache {
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LightPlayer/Thumbnails", isDirectory: true)
    }

    /// Posted (main thread) after the cache was emptied, so open generators forget what they had on disk.
    static let didClear = Notification.Name("ThumbnailCacheDidClear")

    private static let queue = DispatchQueue(label: "thumbnail-cache", qos: .utility)

    /// Folder for one video at one thumbnail width. Files: size + modification date in the key, so a replaced
    /// file gets fresh thumbnails. Streams: the URL without credentials.
    static func folder(for url: URL, pixelWidth: Int) -> URL {
        var id: String
        if url.isFileURL {
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (a?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            id = "\(url.path)|\(size)|\(Int(mtime))"
        } else {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.user = nil; c?.password = nil
            id = c?.string ?? url.absoluteString
        }
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash)-\(pixelWidth)", isDirectory: true)
    }

    /// Total bytes on disk (allocated), computed off the main thread.
    static func size(_ completion: @escaping (Int64) -> Void) {
        queue.async {
            let total = folders().reduce(Int64(0)) { $0 + $1.bytes }
            DispatchQueue.main.async { completion(total) }
        }
    }

    static func clear(_ completion: (() -> Void)? = nil) {
        queue.async {
            try? FileManager.default.removeItem(at: directory)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didClear, object: nil)
                completion?()
            }
        }
    }

    /// Deletes folders unused for longer than `maxAgeDays` (0 = keep forever), then the least recently used ones
    /// until the total is under `maxBytes`. Folders in use by an open video are skipped (they'd just be recreated).
    static func trim(maxBytes: Int64, maxAgeDays: Int, inUse: Set<String> = []) {
        queue.async {
            let fm = FileManager.default
            var list = folders().sorted { $0.used < $1.used }       // oldest first
            if maxAgeDays > 0 {
                let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)
                list.removeAll { f in
                    guard f.used < cutoff, !inUse.contains(f.url.lastPathComponent) else { return false }
                    try? fm.removeItem(at: f.url); return true
                }
            }
            var total = list.reduce(Int64(0)) { $0 + $1.bytes }
            for f in list where total > maxBytes && !inUse.contains(f.url.lastPathComponent) {
                try? fm.removeItem(at: f.url)
                total -= f.bytes
            }
        }
    }

    /// Trim with the current settings (main thread: reads Settings).
    static func trimToSettings(inUse: Set<String> = []) {
        let s = Settings.shared
        trim(maxBytes: Int64(s.thumbnailCacheMB) * 1_000_000, maxAgeDays: s.thumbnailCacheDays, inUse: inUse)
    }

    private struct Folder { let url: URL; let used: Date; let bytes: Int64 }

    private static func folders() -> [Folder] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let dirs = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return dirs.compactMap { d in
            guard let v = try? d.resourceValues(forKeys: Set(keys)), v.isDirectory == true else { return nil }
            let files = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
            let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
            return Folder(url: d, used: v.contentModificationDate ?? .distantPast, bytes: bytes)
        }
    }
}
