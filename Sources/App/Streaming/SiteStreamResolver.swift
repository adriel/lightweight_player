import Foundation

/// YouTube / Twitch: turns a page URL into playable stream URLs by running yt-dlp (like IINA/mpv). Live/HLS goes
/// to AVPlayer; YouTube's separate high-quality video + audio files go to the FFmpeg engine as two inputs
/// (AVFoundation stalls on them).
enum SiteStreamResolver {
    struct Resolved {
        let streamURL: URL
        var audioURL: URL? = nil       // separate audio stream (YouTube's high-quality formats)
        let title: String
        let isLive: Bool
        let headers: [String: String]
        var isHLS: Bool { streamURL.path.hasSuffix(".m3u8") || streamURL.absoluteString.contains("m3u8") }
    }

    enum Failure: Error, CustomStringConvertible {
        case ytDlpMissing, failed(String)
        var description: String {
            switch self {
            case .ytDlpMissing: return "Playing YouTube and Twitch links needs yt-dlp. Install it with Homebrew:  brew install yt-dlp"
            case .failed(let m): return m
            }
        }
    }

    /// Sites handled through yt-dlp (others go straight to the player as direct file links).
    static func handles(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.scheme?.hasPrefix("http") == true else { return false }
        let sites = ["youtube.com", "youtu.be", "twitch.tv", "youtube-nocookie.com"]
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static var ytDlpPath: String? {
        let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs yt-dlp off the main thread; completion on the main thread.
    static func resolve(_ page: URL, completion: @escaping (Result<Resolved, Failure>) -> Void) {
        guard let tool = ytDlpPath else { completion(.failure(.ytDlpMissing)); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            // 1. Live/HLS with audio+video (Twitch, YouTube live) → AVPlayer HLS.
            // 2. YouTube's separate video (VP9 ≤1440p, else H.264 ≤1080p — both hardware-decoded on Apple silicon) +
            //    stereo AAC audio files → FFmpeg engine with two inputs. (YouTube's 5.1 AAC track never starts in
            //    AVSampleBufferAudioRenderer; stereo is what YouTube itself plays on most devices.)
            // 3. Anything with both audio and video.
            let override = ProcessInfo.processInfo.environment["LP_YTDLP_FORMAT"]
            p.arguments = ["--no-playlist", "--no-warnings", "-J",
                           "-f", override ?? "best[protocol^=m3u8][vcodec!=none][acodec!=none]" +
                                 "/bv*[vcodec~='^vp0?9'][height<=1440][protocol=https]+ba[ext=m4a][audio_channels<=2][protocol=https]" +
                                 "/bv*[vcodec^=avc1][height<=1080][protocol=https]+ba[ext=m4a][audio_channels<=2][protocol=https]" +
                                 "/best[vcodec!=none][acodec!=none]",
                           page.absoluteString]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            var result: Result<Resolved, Failure>
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                result = parse(data, error: errText, status: p.terminationStatus)
            } catch {
                result = .failure(.failed("Couldn't run yt-dlp: \(error.localizedDescription)"))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func parse(_ data: Data, error: String, status: Int32) -> Result<Resolved, Failure> {
        guard status == 0, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let line = error.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? "yt-dlp couldn't read this link."
            return .failure(.failed(line.replacingOccurrences(of: "ERROR: ", with: "")))
        }
        let title = (j["title"] as? String) ?? (j["fulltitle"] as? String) ?? "Stream"
        let live = (j["is_live"] as? Bool) ?? false
        // Merged formats ("video+audio") come as requested_formats; a single format puts url/http_headers at the top.
        if let req = j["requested_formats"] as? [[String: Any]], req.count == 2,
           let v = req.first(where: { ($0["vcodec"] as? String ?? "none") != "none" }), let a = req.first(where: { ($0["vcodec"] as? String ?? "none") == "none" }),
           let vu = (v["url"] as? String).flatMap(URL.init(string:)), let au = (a["url"] as? String).flatMap(URL.init(string:)) {
            return .success(Resolved(streamURL: vu, audioURL: au, title: title, isLive: live, headers: (v["http_headers"] as? [String: String]) ?? [:]))
        }
        guard let s = j["url"] as? String, let u = URL(string: s) else { return .failure(.failed("No playable stream found for this link.")) }
        return .success(Resolved(streamURL: u, title: title, isLive: live, headers: (j["http_headers"] as? [String: String]) ?? [:]))
    }
}
