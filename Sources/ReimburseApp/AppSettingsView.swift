import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            TabView {
                AISettingsView(saved: { AppRuntime.shared.aiConfigurationSaved?() })
                    .tabItem { Label("AI 辅助识别", systemImage: "sparkles") }
                QQMailboxSettingsView(saved: {
                    let runtime = AppRuntime.shared
                    runtime.mailbox.configurationChanged()
                    Task { await runtime.mailbox.sync(inbox: runtime.inbox) }
                })
                    .tabItem { Label("QQ 邮箱", systemImage: "envelope") }
                BackgroundSettingsView()
                    .tabItem { Label("后台与通知", systemImage: "bell") }
                CacheSettingsView(cache: AppRuntime.shared.cache)
                    .tabItem { Label("缓存管理", systemImage: "internaldrive") }
            }
            Text("AI、邮箱和缓存上限修改后请保存；后台与通知开关即时生效。")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
        }
        .padding(8)
        .frame(width: 660, height: 610)
    }
}

private struct BackgroundSettingsView: View {
    @ObservedObject private var notifications = AppRuntime.shared.notifications
    @ObservedObject private var startup = AppRuntime.shared.startup

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("后台与通知").font(.title2)
            Toggle("收到新发票时通知我", isOn: Binding(get: { notifications.enabled }, set: { value in
                Task { await notifications.setEnabled(value) }
            }))
            Text("新发票按批汇总提醒。关闭通知不影响收票，点击通知会打开发票箱。")
                .font(.callout).foregroundStyle(.secondary)
            if !notifications.permissionMessage.isEmpty {
                Text(notifications.permissionMessage).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("登录 Mac 后自动启动", isOn: Binding(get: { startup.enabled }, set: { value in
                Task { await startup.setEnabled(value) }
            })).disabled(startup.working)
            if !startup.message.isEmpty { Text(startup.message).font(.caption).foregroundStyle(.secondary) }
            Text("以上开关即时生效。关闭主窗口只隐藏窗口，软件仍会后台收票；从顶部菜单栏选择“退出”或按 ⌘Q 才会停止。电脑需联网且未休眠，新发票附件自动下载识别，历史附件按需下载。")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24).frame(width: 620, height: 510)
        .onAppear { startup.refresh() }
    }
}
