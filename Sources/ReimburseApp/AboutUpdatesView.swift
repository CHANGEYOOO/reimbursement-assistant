import AppKit
import Combine
import SwiftUI

@MainActor private final class AboutUpdatesState: ObservableObject {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "报销单助手"
    @Published var checking = false
    @Published var status = "点击检查更新，查看 GitHub 上的最新正式版本。"
    @Published var result: UpdateCheckResult?
    @Published var checkedAt: Date?

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        result = nil
        status = "正在检查更新…"
        do {
            guard let value = Bundle.main.object(forInfoDictionaryKey: "ReimbursementGitHubRepository") as? String,
                  let repository = GitHubReleaseRepository(value) else { throw UpdateCheckError.configuration }
            let found = try await GitHubUpdateClient(repository: repository, currentVersion: version, architecture: .current).check()
            result = found
            switch found.comparison {
            case .orderedDescending: status = "发现新版本 \(found.release.tag_name)"
            case .orderedSame: status = "当前已是最新正式版本。"
            case .orderedAscending: status = "当前版本比 GitHub 上的最新正式版本 \(found.release.tag_name) 更新。"
            }
        } catch is CancellationError { status = "检查已取消。" }
        catch let error as URLError {
            status = error.code == .timedOut ? "检查超时，请检查网络后重试。" : "无法连接 GitHub，请检查网络后重试。"
        } catch { status = error.localizedDescription }
        checkedAt = Date()
    }
}

struct AboutUpdatesView: View {
    @StateObject private var state = AboutUpdatesState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().scaledToFit().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.appName).font(.title2)
                    Text("当前版本 \(state.version)").foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Button(state.checking ? "正在检查…" : "检查更新") { Task { await state.check() } }
                    .disabled(state.checking)
                if state.checking { ProgressView().controlSize(.small) }
            }
            Text(state.status).textSelection(.enabled)
            if let date = state.checkedAt {
                Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = state.result {
                Divider()
                Text("GitHub 最新正式版：\(result.release.tag_name)").font(.headline)
                ScrollView {
                    Text(result.release.body?.isEmpty == false ? result.release.body! : "此版本未提供更新说明。")
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 205)
                HStack {
                    if result.comparison == .orderedDescending {
                        Button(result.installerURL == nil ? "前往发布页面下载" : "下载更新") {
                            NSWorkspace.shared.open(result.installerURL ?? result.release.html_url)
                        }
                    }
                    Link("查看 GitHub 发布页面", destination: result.release.html_url)
                }
                if result.comparison == .orderedDescending && result.installerURL == nil {
                    Text("未找到能明确匹配本机架构的安装包，请在发布页面确认兼容性后下载。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text("更新来自 GitHub Releases。仅在你点击后打开下载页面，不会自动安装或替换应用。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 620, height: 510)
    }
}
