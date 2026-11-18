import Foundation

/// `LightPlayer --mkvtest file.mkv` — exercises the Matroska parser used by the MediaExtension.
enum MKVTest {
    static func run(_ path: String) {
        do {
            let t0 = Date()
            let f = try MatroskaFile(reader: FileMKVReader(path: path))
            print(String(format: "opened in %.1f ms, duration %.2fs, scale %d", Date().timeIntervalSince(t0) * 1000, Double(f.durationNs) / 1e9, f.timestampScale))
            for t in f.tracks {
                print("track \(t.number) type \(t.type) \(t.codecID) priv \(t.codecPrivate.count)B \(t.width)x\(t.height) sr \(t.sampleRate) ch \(t.channels) lang \(t.language) default \(t.isDefault) forced \(t.isForced) dd \(t.defaultDurationNs) strip \(t.strippedHeader?.count ?? -1) colour \(String(describing: t.colour))")
            }
            for t in f.tracks where t.isVideo || t.isAudio {
                var pos = try f.firstPosition(t.number)
                var line: [String] = []
                for _ in 0..<8 {
                    let s = try f.sample(t.number, pos)
                    line.append(String(format: "p%.3f d%.3f %d%@", Double(s.ptsNs) / 1e9, Double(s.dtsNs) / 1e9, s.size, s.isKey ? "K" : ""))
                    let (np, n) = try f.step(t.number, from: pos, by: 1); if n == 0 { break }; pos = np
                }
                print("  #\(t.number) first:", line.joined(separator: "  "))
                let t1 = Date()
                for target in [0.5, 0.33, 0.9] {
                    let ns = Int64(Double(f.durationNs) * target)
                    let p = try f.position(t.number, atPTS: ns)
                    let s = try f.sample(t.number, p)
                    let (bp, back) = try f.step(t.number, from: p, by: -30)
                    let (_, fwd) = try f.step(t.number, from: bp, by: 30)
                    print(String(format: "  #%d seek %.2f -> pts %.3f key %@ back %lld fwd %lld", t.number, Double(ns) / 1e9, Double(s.ptsNs) / 1e9, s.isKey ? "Y" : "n", back, fwd))
                }
                let last = try f.lastPosition(t.number)
                let ls = try f.sample(t.number, last)
                print(String(format: "  #%d last pts %.3f  (lookups %.1f ms)", t.number, Double(ls.ptsNs) / 1e9, Date().timeIntervalSince(t1) * 1000))
            }
        } catch { print("ERROR", error) }
    }
}
