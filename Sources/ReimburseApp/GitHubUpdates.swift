import Foundation
import Darwin

struct ReleaseVersion: Comparable, Sendable {
    let components: [Int]

    init?(_ value: String) {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        let parts = value.split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty,
              parts.count == 1 || parts[1].range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(numbers.count) else { return nil }
        var parsed: [Int] = []
        for number in numbers {
            guard !number.isEmpty, number.allSatisfy({ $0 >= "0" && $0 <= "9" }), let integer = Int(number) else { return nil }
            parsed.append(integer)
        }
        while parsed.count > 1 && parsed.last == 0 { parsed.removeLast() }
        components = parsed
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

enum MacReleaseArchitecture: String, Sendable {
    case arm64, x86_64
    static var current: Self {
        var value: Int32 = 0
        var length = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &length, nil, 0) == 0 && value == 1 ? .arm64 : .x86_64
    }
}

struct GitHubReleaseRepository: Sendable {
    let name: String
    init?(_ name: String) {
        guard name.range(of: #"^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else { return nil }
        self.name = name
    }
    var apiURL: URL { URL(string: "https://api.github.com/repos/\(name)/releases?per_page=100")! }
    func allows(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.lowercased() == "github.com", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return false }
        return url.path.lowercased().hasPrefix("/\(name.lowercased())/releases/")
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let label: String?
        let browser_download_url: URL
    }
    let tag_name: String
    let name: String?
    let body: String?
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    static func latest(in data: Data, repository: GitHubReleaseRepository) throws -> Self {
        let releases = try JSONDecoder().decode([Self].self, from: data)
        guard let newest = releases.filter({ !$0.draft && !$0.prerelease && ReleaseVersion($0.tag_name) != nil && repository.allows($0.html_url) })
            .max(by: { ReleaseVersion($0.tag_name)! < ReleaseVersion($1.tag_name)! }) else { throw UpdateCheckError.noRelease }
        return newest
    }

    func installer(for architecture: MacReleaseArchitecture, repository: GitHubReleaseRepository) -> URL? {
        let candidates = assets.compactMap { asset -> (URL, Int)? in
            let url = asset.browser_download_url
            let parts = url.pathComponents
            guard repository.allows(url), parts.count == 7, parts[4] == "download", parts[5] == tag_name,
                  ["dmg", "pkg", "zip"].contains(url.pathExtension.lowercased()) else { return nil }
            let text = (asset.name + " " + (asset.label ?? "")).lowercased()
            guard !text.contains("windows"), !text.contains("linux"),
                  url.pathExtension.lowercased() != "zip" || text.contains("mac") || text.contains("darwin") else { return nil }
            let universal = text.contains("universal") || text.contains("通用")
            let arm = text.contains("arm64") || text.contains("aarch64") || text.contains("apple silicon") || text.contains("apple芯片") || text.contains("apple 芯片")
            let intel = text.contains("x86_64") || text.contains("x64") || text.contains("intel") || text.contains("amd64")
            guard universal || (architecture == .arm64 ? arm && !intel : intel && !arm) else { return nil }
            return (url, universal ? 2 : 3)
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }
}

enum UpdateCheckError: LocalizedError {
    case configuration, currentVersion, noRelease, rateLimited, unavailable(Int), malformed, tooLarge
    var errorDescription: String? {
        switch self {
        case .configuration: "这个安装包尚未配置更新仓库，无法检查更新。"
        case .currentVersion: "无法读取当前应用的版本号。"
        case .noRelease: "GitHub 暂无可用的正式版本。"
        case .rateLimited: "GitHub 暂时限制了访问次数，请稍后再试。"
        case .unavailable(let code): "暂时无法取得版本信息（HTTP \(code)），请稍后再试。"
        case .malformed: "GitHub 返回的版本信息无法读取，请稍后再试。"
        case .tooLarge: "版本信息过大，检查已停止。"
        }
    }
}

struct UpdateCheckResult: Sendable {
    let release: GitHubRelease
    let comparison: ComparisonResult
    let installerURL: URL?
}

struct GitHubUpdateClient: Sendable {
    let repository: GitHubReleaseRepository
    let currentVersion: String
    let architecture: MacReleaseArchitecture

    func interpret(_ data: Data, status: Int) throws -> UpdateCheckResult {
        guard status != 403 && status != 429 else { throw UpdateCheckError.rateLimited }
        guard status == 200 else { throw UpdateCheckError.unavailable(status) }
        guard data.count <= 2 * 1024 * 1024 else { throw UpdateCheckError.tooLarge }
        guard let current = ReleaseVersion(currentVersion) else { throw UpdateCheckError.currentVersion }
        let release: GitHubRelease
        do { release = try GitHubRelease.latest(in: data, repository: repository) }
        catch is DecodingError { throw UpdateCheckError.malformed }
        let latest = ReleaseVersion(release.tag_name)!
        let comparison: ComparisonResult = latest > current ? .orderedDescending : latest < current ? .orderedAscending : .orderedSame
        return UpdateCheckResult(release: release, comparison: comparison,
            installerURL: release.installer(for: architecture, repository: repository))
    }

    func check() async throws -> UpdateCheckResult {
        var request = URLRequest(url: repository.apiURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ReimbursementAssistant/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw UpdateCheckError.malformed }
        return try interpret(data, status: response.statusCode)
    }
}
