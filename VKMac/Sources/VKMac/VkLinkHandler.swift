import AppKit
import Foundation
import SwiftUI

enum VkLinkHandler {
    private static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "fbclid", "yclid", "gclid", "mc_cid", "mc_eid", "ref"
    ]

    static func cleanURL(_ url: URL) -> URL {
        // Unwrap vk.com/away.php?to=...
        if let host = url.host?.lowercased(),
           (host.contains("vk.com") || host.contains("vk.ru")),
           url.path == "/away.php",
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let toVal = comps.queryItems?.first(where: { $0.name == "to" })?.value,
           let target = URL(string: toVal) {
            return cleanURL(target)
        }

        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        if let items = comps.queryItems, !items.isEmpty {
            let filtered = items.filter { !trackingParams.contains($0.name.lowercased()) }
            comps.queryItems = filtered.isEmpty ? nil : filtered
        }
        return comps.url ?? url
    }

    @MainActor
    static func handle(_ rawUrl: URL, appState: AppState) -> OpenURLAction.Result {
        let url = cleanURL(rawUrl)
        guard let host = url.host?.lowercased(),
              host == "vk.com" || host.hasSuffix(".vk.com") || host == "vk.ru" || host.hasSuffix(".vk.ru") else {
            NSWorkspace.shared.open(url)
            return .handled
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            NSWorkspace.shared.open(url)
            return .handled
        }

        let segment = path.split(separator: "/").first.map(String.init) ?? path

        if segment.hasPrefix("id"), let uid = Int64(segment.dropFirst(2)), uid > 0 {
            appState.openOwnerPage(uid)
            return .handled
        }
        if segment.hasPrefix("club"), let gid = Int64(segment.dropFirst(4)), gid > 0 {
            appState.openOwnerPage(-gid)
            return .handled
        }
        if segment.hasPrefix("public"), let gid = Int64(segment.dropFirst(6)), gid > 0 {
            appState.openOwnerPage(-gid)
            return .handled
        }
        if segment.hasPrefix("event"), let gid = Int64(segment.dropFirst(5)), gid > 0 {
            appState.openOwnerPage(-gid)
            return .handled
        }

        if segment.hasPrefix("wall") {
            let body = String(segment.dropFirst(4))
            let parts = body.split(separator: "_")
            if parts.count == 2, let ownerId = Int64(parts[0]), let postId = Int64(parts[1]) {
                Task { await appState.openWallPost(ownerId: ownerId, postId: postId) }
                return .handled
            }
        }

        let reserved: Set<String> = ["feed", "im", "audio", "video", "videos", "friends", "groups", "fave", "settings", "away.php", "doc", "docs", "photo", "photos", "app"]
        if !reserved.contains(segment.lowercased()), !segment.contains(".") {
            Task { await appState.openScreenName(segment, fallbackUrl: url) }
            return .handled
        }

        NSWorkspace.shared.open(url)
        return .handled
    }
}
