#if DIRECT_TEST_RUNNER
import Foundation

@main struct GitHubUpdateCheck {
    static func main() throws {
        func check(_ condition: Bool, _ message: String = "") { precondition(condition, message) }
        check(ReleaseVersion("v1.9")! < ReleaseVersion("1.10.0")!)
        check(ReleaseVersion("1.28") == ReleaseVersion("v1.28.0+build32"))
        check(ReleaseVersion("1.28.0-beta") == nil)
        check(ReleaseVersion("1..2") == nil)
        check(ReleaseVersion("99999999999999999999999999") == nil)
        check(GitHubReleaseRepository("https://github.com/example/repo") == nil)
        let repository = GitHubReleaseRepository("example/repo")!
        func asset(_ name: String, label: String? = nil, tag: String = "v1.10.0") -> [String: Any] {
            var result: [String: Any] = ["name": name, "browser_download_url": "https://github.com/example/repo/releases/download/\(tag)/\(name)"]
            if let label { result["label"] = label }
            return result
        }
        func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, assets: [[String: Any]] = []) -> [String: Any] {
            ["tag_name": tag, "name": tag, "body": "用户更新说明", "html_url": "https://github.com/example/repo/releases/tag/\(tag)", "draft": draft, "prerelease": prerelease, "assets": assets]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            release("v2.0.0", draft: true), release("v1.99.0", prerelease: true), release("v1.9.0"),
            release("v1.10.0", assets: [asset("Mac-arm64.dmg"), asset("Mac-x64.dmg"), asset("Windows-x64.exe"), asset("Mac-universal.zip")])
        ])
        let client = GitHubUpdateClient(repository: repository, currentVersion: "1.9", architecture: .arm64)
        let result = try client.interpret(data, status: 200)
        check(result.release.tag_name == "v1.10.0" && result.comparison == .orderedDescending)
        check(result.installerURL?.lastPathComponent == "Mac-arm64.dmg")
        check(result.release.installer(for: .x86_64, repository: repository)?.lastPathComponent == "Mac-x64.dmg")
        check(try GitHubUpdateClient(repository: repository, currentVersion: "1.10", architecture: .arm64).interpret(data, status: 200).comparison == .orderedSame)
        check(try GitHubUpdateClient(repository: repository, currentVersion: "1.28", architecture: .arm64).interpret(data, status: 200).comparison == .orderedAscending)
        let legacy = try JSONSerialization.data(withJSONObject: [release("v1.10.0", assets: [asset("ReimbursementAssistant-macOS-1.10.dmg")])])
        check(try client.interpret(legacy, status: 200).installerURL == nil, "Unknown architecture must fall back to release page")
        let labelled = try JSONSerialization.data(withJSONObject: [release("v1.10.0", assets: [asset("Mac.dmg", label: "Apple Silicon")])])
        check(try client.interpret(labelled, status: 200).installerURL?.lastPathComponent == "Mac.dmg")
        let wrongTag = try JSONSerialization.data(withJSONObject: [release("v1.10.0", assets: [asset("Mac-arm64.dmg", tag: "v1.9.0")])])
        check(try client.interpret(wrongTag, status: 200).installerURL == nil)
        for url in ["http://github.com/example/repo/releases/tag/v2", "https://github.com.evil.invalid/example/repo/releases/tag/v2", "https://github.com/example/other/releases/tag/v2", "https://user:secret@github.com/example/repo/releases/tag/v2"] {
            check(!repository.allows(URL(string: url)!))
        }
        for status in [403, 429, 404, 500] {
            var failed = false
            do { _ = try client.interpret(Data(), status: status) } catch { failed = true }
            check(failed)
        }
        var rejected = false
        do { _ = try client.interpret(Data("not json".utf8), status: 200) } catch { rejected = true }
        check(rejected)
        rejected = false
        do { _ = try client.interpret(Data("[]".utf8), status: 200) } catch { rejected = true }
        check(rejected)
        print("GitHub update checks passed: numeric versions, formal releases, architecture, URL boundaries and errors; no network or download")
    }
}
#endif
