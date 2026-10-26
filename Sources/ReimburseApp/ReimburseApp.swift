import SwiftUI

public struct ReimburseApp: App {
    @NSApplicationDelegateAdaptor(BackgroundAppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        Window("报销单助手", id: "main") {
            ReviewView()
                .background(MainWindowAttachment(delegate: appDelegate).frame(width: 0, height: 0))
        }
        Settings { AppSettingsView() }
        MenuBarExtra("报销单助手", systemImage: "doc.text.image") {
            BackgroundStatusMenu()
        }
    }
}
