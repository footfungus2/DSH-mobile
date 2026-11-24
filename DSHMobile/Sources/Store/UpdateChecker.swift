import SwiftUI

/// Checks the GitHub Releases feed for a newer build and hands the SideStore
/// install manifest back to the system so the update applies in place.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String)
        case handedOff
        case failed(String)
    }

    static let repo = "footfungus2/DSH-mobile"

    private(set) var state: State = .idle

    var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func checkAndInstall() async {
        state = .checking
        do {
            let latest = try await fetchLatestTag()
            if versionCompare(latest, installedVersion) <= 0 {
                state = .upToDate(latest)
                return
            }
            state = .available(latest)
            installViaSideStore()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func fetchLatestTag() async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DSHError.handshakeFailed("no response from GitHub")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404 { throw DSHError.handshakeFailed("No releases published yet.") }
            throw DSHError.handshakeFailed("release lookup returned HTTP \(http.statusCode)")
        }
        struct Release: Decodable { let tag_name: String }
        let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private func installViaSideStore() {
        // The manifest lives beside the ipa on the latest release.
        let manifest = "https://github.com/\(Self.repo)/releases/latest/download/manifest.json"
        let encoded = manifest.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? manifest
        guard let url = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else { return }
        // canOpenURL needs plist whitelisting; open's completion is the honest check.
        UIApplication.shared.open(url) { [weak self] accepted in
            Task { @MainActor in
                if accepted {
                    self?.state = .handedOff
                } else if let page = URL(string: "https://github.com/\(Self.repo)/releases/latest") {
                    // No sideloading handler installed: fall back to the release page.
                    UIApplication.shared.open(page)
                }
            }
        }
    }

    private func versionCompare(_ lhs: String, _ rhs: String) -> Int {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}
