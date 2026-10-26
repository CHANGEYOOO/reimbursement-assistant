import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor final class AppRuntime: ObservableObject {
    static let shared = AppRuntime()
    let inbox = InvoiceInboxStore()
    let mailbox = MailboxSyncController()
    let notifications = InvoiceNotificationController()
    let startup = LoginItemController()
    @Published private(set) var inboxOpenRequest = 0
    var saveBeforeExit: (() -> Bool)?
    var aiConfigurationSaved: (() -> Void)?
    private var pollingTask: Task<Void, Never>?
    private var mainWindow: NSWindow?
    private var launchHidden = false

    func start() {
        guard pollingTask == nil else { return }
        notifications.openInbox = { [weak self] in self?.openInbox() }
        mailbox.onNewInvoices = { [weak self] count, historical in
            self?.notifications.notify(count: count, historical: historical)
        }
        pollingTask = Task { await mailbox.run(inbox: inbox) }
    }

    func attach(_ window: NSWindow, delegate: BackgroundAppDelegate) {
        mainWindow = window
        window.delegate = delegate
        if launchHidden { window.orderOut(nil) }
    }

    func setLoginLaunch(_ hidden: Bool) {
        launchHidden = hidden
        if hidden { mainWindow?.orderOut(nil) }
    }

    func showMainWindow() {
        launchHidden = false
        mainWindow?.deminiaturize(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func openInbox() {
        inboxOpenRequest += 1
        showMainWindow()
    }

    func prepareToLeave() -> Bool {
        mainWindow?.makeFirstResponder(nil)
        return saveBeforeExit?() ?? true
    }

    func stop() { pollingTask?.cancel(); pollingTask = nil }
}

@MainActor final class BackgroundAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue == true
        AppRuntime.shared.setLoginLaunch(loginLaunch)
        AppRuntime.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppRuntime.shared.startup.refresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppRuntime.shared.showMainWindow()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard AppRuntime.shared.prepareToLeave() else { return false }
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppRuntime.shared.prepareToLeave() else {
            AppRuntime.shared.showMainWindow()
            return .terminateCancel
        }
        AppRuntime.shared.stop()
        return .terminateNow
    }
}

@MainActor final class LoginItemController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var working = false
    @Published private(set) var message = ""
    private var lastStatus: SMAppService.Status?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        let changed = status != lastStatus
        lastStatus = status
        enabled = status == .enabled || status == .requiresApproval
        if status == .requiresApproval {
            message = "请在系统设置 → 通用 → 登录项中允许报销单助手。"
        } else if changed { message = "" }
    }

    func setEnabled(_ value: Bool) async {
        guard !working else { return }
        message = ""
        working = true
        defer { working = false }
        do {
            if value {
                let status = SMAppService.mainApp.status
                if status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered {
                try await SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh()
            message = "无法更改登录启动设置：\(error.localizedDescription)。请先将软件安装到“应用程序”文件夹。"
        }
    }
}

struct BackgroundStatusMenu: View {
    @ObservedObject private var mailbox = AppRuntime.shared.mailbox
    @ObservedObject private var inbox = AppRuntime.shared.inbox
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("报销单助手")
        if mailbox.syncing { Text("正在同步邮件信息…") }
        else if let date = mailbox.lastSyncAt {
            Text("上次同步：\(date.formatted(date: .omitted, time: .shortened))")
        } else { Text("尚未完成邮箱同步") }
        Text("未分配发票：\(inbox.items.filter { $0.projectID == nil }.count) 张")
        Text("\(mailbox.status.prefix(40))\(mailbox.status.count > 40 ? "…" : "")").help(mailbox.status)
        Divider()
        Button("打开报销单助手") {
            openWindow(id: "main")
            AppRuntime.shared.showMainWindow()
        }
        Button("立即同步") { Task { await mailbox.sync(inbox: inbox) } }
            .disabled(mailbox.syncing)
        Button("设置…") {
            NSApp.activate()
            openSettings()
        }
        Divider()
        Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct MainWindowAttachment: NSViewRepresentable {
    let delegate: BackgroundAppDelegate
    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.attach = { window in AppRuntime.shared.attach(window, delegate: delegate) }
        return view
    }
    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {}
}

final class WindowAttachmentView: NSView {
    var attach: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { attach?(window) }
    }
}
