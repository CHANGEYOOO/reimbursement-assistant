import AppKit
import Combine
import SwiftUI
import WebKit

struct MailMessageIdentity: Equatable, Sendable {
    let account: String
    let validity: String
    let uid: UInt64
    init(id: String) throws {
        let values = id.split(separator: "|", omittingEmptySubsequences: false)
        guard values.count == 3, !values[0].isEmpty, UInt64(values[1]) != nil,
              let uid = UInt64(values[2]), uid > 0 else { throw QQMailboxError.changedMailbox }
        account = String(values[0]); validity = String(values[1]); self.uid = uid
    }
}

struct MailBody: Sendable {
    let text: String
    let html: String?
    static func externalURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    var attributedText: AttributedString {
        let value = NSMutableAttributedString(string: text)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(location: 0, length: value.length)) {
                if let raw = match.url?.absoluteString, let url = Self.externalURL(raw) {
                    value.addAttribute(.link, value: url, range: match.range)
                }
            }
        }
        return AttributedString(value)
    }
    var links: [URL] {
        let source = html ?? text
        let pattern = html == nil ? #"https?://[^\s<>\"']+"# : #"(?i)href\s*=\s*[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        var result: [URL] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range(at: html == nil ? 0 : 1)).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = Self.externalURL(raw), !result.contains(url), result.count < 30 else { continue }
            let lower = raw.lowercased()
            if ["invoice", "fapiao", "download", ".pdf", "发票", "下载"].contains(where: lower.contains) { result.append(url) }
        }
        return result
    }
    var safeHTML: String {
        // CSP is the security boundary; mail markup never receives script or network permission.
        """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"><meta name="viewport" content="width=device-width"><style>body{font:14px -apple-system;overflow-wrap:anywhere;margin:16px;color:#202020;background:white}img{max-width:100%;height:auto}table{max-width:100%}pre{white-space:pre-wrap}</style></head><body>\(html ?? "")</body></html>
        """
    }
}

@MainActor enum MailHTMLSecurity {
    nonisolated static let rulesJSON = #"[{"trigger":{"url-filter":"^https?://","url-filter-is-case-sensitive":false},"action":{"type":"block"}}]"#
    private static var rules: WKContentRuleList?
    private static var waiting: [@MainActor (WKContentRuleList?) -> Void] = []
    static func prepare(_ completion: @escaping @MainActor (WKContentRuleList?) -> Void) {
        if let rules { completion(rules); return }
        waiting.append(completion)
        guard waiting.count == 1 else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "mail-block-remote-v1", encodedContentRuleList: rulesJSON) { list, _ in
            rules = list
            let callbacks = waiting
            waiting.removeAll()
            callbacks.forEach { $0(list) }
        }
    }
}

@MainActor final class MailDetailState: ObservableObject {
    @Published var selected: MailboxManualNotice?
    @Published private(set) var body: MailBody?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var cache: [String: MailBody] = [:]
    private var order: [String] = []
    private var pending: [String: Task<MailBody, Error>] = [:]
    private var token = UUID()
    func close() {
        token = UUID(); selected = nil; body = nil; error = nil; loading = false
    }
    func toggle(_ notice: MailboxManualNotice) {
        if selected?.id == notice.id { close(); return }
        token = UUID()
        let request = token
        selected = notice; body = nil; error = nil; loading = false
        let revision = QQMailboxConfiguration.revision
        do {
            let identity = try MailMessageIdentity(id: notice.id)
            guard identity.account == QQMailboxConfiguration.address else { throw QQMailboxError.changedMailbox }
            if let cached = cache[notice.id] { body = cached; return }
            let credentials = try QQMailboxConfiguration.credentials()
            let fetch: Task<MailBody, Error>
            if let existing = pending[notice.id] { fetch = existing }
            else {
                guard pending.count < 4 else { throw QQMailboxError.connection }
                fetch = Task { try await QQMailboxClient.fetchBody(credentials: credentials, id: notice.id) }
                pending[notice.id] = fetch
            }
            loading = true
            Task {
                do {
                    let result = try await fetch.value
                    pending.removeValue(forKey: notice.id)
                    guard !Task.isCancelled, revision == QQMailboxConfiguration.revision,
                          QQMailboxConfiguration.address == credentials.address else { return }
                    if cache[notice.id] == nil { order.append(notice.id) }; cache[notice.id] = result
                    while order.count > 8 { cache.removeValue(forKey: order.removeFirst()) }
                    guard token == request else { return }
                    body = result; loading = false
                } catch {
                    pending.removeValue(forKey: notice.id)
                    guard token == request, !Task.isCancelled else { return }
                    self.error = error.localizedDescription; loading = false
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func reset() { close(); pending.values.forEach { $0.cancel() }; pending.removeAll(); cache.removeAll(); order.removeAll() }
}

private struct MailDetailOpenKey: EnvironmentKey { static let defaultValue = false }
private struct CloseMailDetailKey: EnvironmentKey { static let defaultValue: @MainActor @Sendable () -> Void = {} }
extension EnvironmentValues {
    var mailDetailIsOpen: Bool { get { self[MailDetailOpenKey.self] } set { self[MailDetailOpenKey.self] = newValue } }
    var closeMailDetail: @MainActor @Sendable () -> Void { get { self[CloseMailDetailKey.self] } set { self[CloseMailDetailKey.self] = newValue } }
}

struct InvoiceMailboxContent<Content: View>: View {
    @ObservedObject var mailbox: MailboxSyncController
    @StateObject private var detail = MailDetailState()
    let content: Content
    init(mailbox: MailboxSyncController, @ViewBuilder content: () -> Content) {
        self.mailbox = mailbox; self.content = content()
    }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if !mailbox.manualMessages.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("需要手动下载的发票邮件").font(.headline)
                            ForEach(mailbox.manualMessages) { notice in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(notice.subject).lineLimit(1)
                                        Text(notice.sender).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Button(detail.selected?.id == notice.id ? "收起邮件" : "查看邮件") { detail.toggle(notice) }
                                    Button("已手动处理") { mailbox.dismissNotice(notice.id); if detail.selected?.id == notice.id { detail.close() } }
                                }.padding(6).background(detail.selected?.id == notice.id ? Color.accentColor.opacity(0.08) : Color.clear)
                            }
                        }.padding(12)
                    }.frame(maxHeight: 180)
                    Divider()
                }
                content.environment(\.mailDetailIsOpen, detail.selected != nil)
                    .environment(\.closeMailDetail, { detail.close() })
            }.frame(minWidth: 650, maxWidth: .infinity, maxHeight: .infinity)
            if let notice = detail.selected {
                MailDetailView(notice: notice, state: detail).frame(minWidth: 360, idealWidth: 440, maxWidth: 600)
            }
        }
        .onChange(of: mailbox.configurationGeneration) { _, _ in detail.reset() }
        .onDisappear { detail.close() }
    }
}

private struct MailDetailView: View {
    let notice: MailboxManualNotice
    @ObservedObject var state: MailDetailState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("邮件详情").font(.headline); Spacer(); Button(action: state.close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起邮件详情") }
            Text(notice.subject).font(.title3).textSelection(.enabled)
            Text(notice.sender).textSelection(.enabled)
            Text(notice.receivedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            Divider()
            if state.loading { ProgressView("正在读取邮件正文…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error = state.error { ContentUnavailableView("无法读取邮件", systemImage: "envelope.badge", description: Text(error)) }
            else if let body = state.body {
                if !body.links.isEmpty {
                    Text("发票下载候选链接（未经验证）").font(.subheadline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(body.links.enumerated()), id: \.element.absoluteString) { index, url in
                        Button("\(index + 1). \(url.absoluteString)") { NSWorkspace.shared.open(url) }
                            .lineLimit(2).truncationMode(.middle).help(url.absoluteString)
                    }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 140)
                }
                if let html = body.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { MailHTMLView(html: body.safeHTML).id(notice.id) }
                else if body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ContentUnavailableView("邮件正文为空", systemImage: "envelope.open") }
                else { ScrollView { Text(body.attributedText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
            }
            Text("只读查看；远程图片已阻止。链接仅在点击后通过浏览器打开。").font(.caption).foregroundStyle(.secondary)
        }.padding(14).frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct MailHTMLView: NSViewRepresentable {
    let html: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        MailHTMLSecurity.prepare { [weak view] rules in
            guard let view else { return }
            guard let rules else {
                view.loadHTMLString(MailBody(text: "", html: "<p>邮件安全规则加载失败，请收起后重新打开。</p>").safeHTML, baseURL: nil)
                return
            }
            view.configuration.userContentController.add(rules)
            view.loadHTMLString(html, baseURL: nil)
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url,
               let safe = MailBody.externalURL(url.absoluteString) { NSWorkspace.shared.open(safe) }
            if action.navigationType == .other, action.request.url?.absoluteString == "about:blank", action.targetFrame?.isMainFrame == true {
                decisionHandler(.allow)
            } else { decisionHandler(.cancel) }
        }
    }
}
