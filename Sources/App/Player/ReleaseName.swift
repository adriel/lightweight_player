import Foundation

/// Parses "scene-style" release file names into something readable:
///   Show.Name.S01E12.Episode.Title.1080p.BluRay.DD2.0.H.264-GROUP.mkv
///   → title "Show Name", episode "S01E12", episodeTitle "Episode Title", quality "1080p",
///     source "BluRay", container "MKV"
/// Returns nil when the name doesn't look like a release (so ordinary file names are shown as they are).
struct ReleaseName: Equatable {
    var title: String
    var year: String?
    var episode: String?           // "S01E12", "S01E01-E02"
    var episodeTitle: String?
    var quality: String?           // "2160p", "1080p", …
    var source: String?            // "BluRay", "WEB-DL", "Remux", …
    var hdr: String?               // "HDR", "DV", "HDR10+"
    var container: String?         // "MKV"

    init?(fileName: String) {
        var name = fileName.removingPercentEncoding ?? fileName
        let ext = (name as NSString).pathExtension.lowercased()
        let videoExts: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts", "wmv", "flv"]
        if videoExts.contains(ext) { name = (name as NSString).deletingPathExtension; container = ext.uppercased() }
        // Drop the release group ("-GROUP") and bracketed tags.
        if let r = name.range(of: #"-[A-Za-z0-9]+$"#, options: .regularExpression) { name.removeSubrange(r) }
        name = name.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        let tokens = name.split(whereSeparator: { ".  _".contains($0) }).map(String.init)
        guard tokens.count >= 2 else { return nil }

        func match(_ t: String, _ pattern: String) -> Bool { t.range(of: "^(?:\(pattern))$", options: [.regularExpression, .caseInsensitive]) != nil }
        let qualityRE = #"\d{3,4}[pi]|4K|UHD"#
        let sourceRE = #"Blu-?Ray|BDRip|BRRip|BDRemux|Remux|WEB-?DL|WEBRip|WEB|HDTV|DVDRip|DVD|AMZN|NF|DSNP|HMAX|ATVP|HULU|iT"#
        let hdrRE = #"HDR10\+?|HDR|DV|DoVi|Dolby-?Vision|HLG"#
        let techRE = #"x26[45]|[hH]\.?26[45]|HEVC|AVC|AV1|VP9|XviD|DivX|10bit|8bit|DD[P+]?\d?\.?\d?|DDP\d\.\d|EAC3|E-?AC-?3|AC3|AAC\d?\.?\d?|DTS(-HD)?|MA|TrueHD|Atmos|FLAC|Opus|\d\.\d|REPACK|PROPER|INTERNAL|LIMITED|EXTENDED|UNCUT|IMAX|REMASTERED|MULTi|SUBBED|DUBBED|COMPLETE"#
        let episodeRE = #"S\d{1,2}E\d{1,3}(?:-?E\d{1,3})*|S\d{1,2}|\d{1,2}x\d{2,3}"#
        let yearRE = #"\(?(19|20)\d{2}\)?"#

        var titleEnd: Int?
        var signals = 0
        var afterEpisode: Int?
        for (i, t) in tokens.enumerated() {
            if episode == nil, i > 0, match(t, episodeRE) {
                episode = Self.normalizeEpisode(t); titleEnd = titleEnd ?? i; afterEpisode = i + 1; signals += 2
            } else if year == nil, i > 0, episode == nil, match(t, yearRE) {
                year = t.trimmingCharacters(in: CharacterSet(charactersIn: "()")); titleEnd = titleEnd ?? i; signals += 1
            } else if quality == nil, match(t, qualityRE) {
                quality = t.lowercased() == "uhd" || t.uppercased() == "4K" ? "2160p" : t.lowercased(); titleEnd = titleEnd ?? i; signals += 2
            } else if match(t, sourceRE) {
                let pretty = Self.prettySource(t)
                if source == nil || pretty == "Remux" { source = pretty }      // "BluRay … Remux" → Remux
                titleEnd = titleEnd ?? i; signals += 1
            } else if match(t, hdrRE) {
                if hdr == nil { hdr = t.uppercased().hasPrefix("DV") || t.lowercased().hasPrefix("dolby") || t.lowercased() == "dovi" ? "Dolby Vision" : t.uppercased() }
                titleEnd = titleEnd ?? i; signals += 1
            } else if match(t, techRE) {
                titleEnd = titleEnd ?? i; signals += 1
            }
        }
        // Needs to look like a release: an episode/quality marker plus something else, or several tech tags.
        guard signals >= 3, let end = titleEnd, end > 0 else { return nil }
        title = Self.titleCase(tokens[0..<end].joined(separator: " "))
        if let a = afterEpisode {
            // Episode title = words between the episode marker and the first tech token.
            var e = a
            while e < tokens.count, !(match(tokens[e], qualityRE) || match(tokens[e], sourceRE) || match(tokens[e], hdrRE) || match(tokens[e], techRE)) { e += 1 }
            if e > a { episodeTitle = tokens[a..<e].joined(separator: " ") }
        }
    }

    /// "Show Name S01E12" (+ year for films).
    var headline: String {
        if let episode { return "\(title) \(episode)" }
        if let year { return "\(title) (\(year))" }
        return title
    }

    private static func normalizeEpisode(_ t: String) -> String {
        let u = t.uppercased()
        if let m = u.range(of: #"^(\d{1,2})X(\d{2,3})$"#, options: .regularExpression) {
            let parts = u[m].split(separator: "X")
            return String(format: "S%02dE%02d", Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
        }
        // Zero-pad: S1E2 → S01E02.
        var out = "", num = "", prefix: Character = " "
        func flush() { if !num.isEmpty { out += String(prefix) + (num.count < 2 ? "0" + num : num); num = "" } }
        for ch in u {
            if ch == "S" || ch == "E" { flush(); prefix = ch } else if ch.isNumber { num.append(ch) } else if ch == "-" { flush(); out += "-" }
        }
        flush()
        return out
    }

    private static func prettySource(_ t: String) -> String {
        switch t.lowercased().replacingOccurrences(of: "-", with: "") {
        case "bluray", "bdrip", "brrip": return "BluRay"
        case "bdremux", "remux": return "Remux"
        case "webdl": return "WEB-DL"
        case "webrip": return "WEBRip"
        case "web": return "WEB"
        case "hdtv": return "HDTV"
        case "dvdrip", "dvd": return "DVD"
        case "amzn": return "Amazon"
        case "nf": return "Netflix"
        case "dsnp": return "Disney+"
        case "hmax": return "Max"
        case "atvp": return "Apple TV+"
        case "hulu": return "Hulu"
        case "it": return "iTunes"
        default: return t
        }
    }

    /// Keeps existing capitals ("of" stays lowercase in "Name of the Show"); capitalises all-lowercase names.
    private static func titleCase(_ s: String) -> String {
        // Country suffixes ("show.name.uk" → "Show Name UK"); not "us", which is usually a word ("Show About Us").
        let countries: Set<String> = ["uk", "nz", "au", "ca"]
        guard s == s.lowercased() else { return s }
        let small: Set<String> = ["a", "an", "and", "the", "of", "in", "on", "at", "to", "for", "vs"]
        return s.split(separator: " ").enumerated().map { i, w in
            countries.contains(String(w)) && i > 0 ? w.uppercased() :
            i > 0 && small.contains(String(w)) ? String(w) : w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}

import SwiftUI

/// How a parsed release name is shown (A–D, see the design comparison); ordinary names are shown as-is.
enum ReleaseNameStyle: String { case plain = "A", emphasised = "B", tags = "C", detailed = "D"
    static var current: ReleaseNameStyle {
        ProcessInfo.processInfo.environment["LP_NAME_STYLE"].flatMap { ReleaseNameStyle(rawValue: $0.uppercased()) } ?? .detailed
    }
}

struct MediaNameView: View {
    let fileName: String
    var style: ReleaseNameStyle = .current

    var body: some View {
        if let r = ReleaseName(fileName: fileName) {
            parsed(r)
        } else {
            Text(fileName).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
        }
    }

    @ViewBuilder private func parsed(_ r: ReleaseName) -> some View {
        let tech = [r.quality, r.container].compactMap { $0 }
        switch style {
        case .plain:
            Text(([r.headline] + tech).joined(separator: " · ")).foregroundStyle(.primary).lineLimit(1)
        case .emphasised:
            HStack(spacing: 4) {
                Text(r.title).fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1)
                Text(r.episode ?? r.year.map { "(\($0))" } ?? "").foregroundStyle(.primary)
                if !tech.isEmpty { Text("·").foregroundStyle(.tertiary); Text(tech.joined(separator: " ")) }
            }
        case .tags:
            HStack(spacing: 5) {
                Text(r.headline).fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1)
                ForEach(tech, id: \.self) { TagView(text: $0) }
            }
        case .detailed:
            // Full line if it fits; otherwise shorten, then drop, the episode title (tags always stay).
            ViewThatFits(in: .horizontal) {
                detailedRow(r, episodeTitle: .full)
                detailedRow(r, episodeTitle: .truncated)
                detailedRow(r, episodeTitle: .hidden)
            }
        }
    }
}

private enum EpisodeTitleFit { case full, truncated, hidden }

extension MediaNameView {
    fileprivate func detailedRow(_ r: ReleaseName, episodeTitle fit: EpisodeTitleFit) -> some View {
        HStack(spacing: 5) {
            Text(r.headline).fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1).fixedSize()
            if let et = r.episodeTitle, fit != .hidden {
                if fit == .full { Text(et).foregroundStyle(.tertiary).lineLimit(1).fixedSize() }
                else { Text(et).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail).frame(minWidth: 40) }
            }
            ForEach([r.quality, r.hdr ?? r.source].compactMap { $0 }, id: \.self) { TagView(text: $0) }
        }
    }
}

struct TagView: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
            .fixedSize()
    }
}
