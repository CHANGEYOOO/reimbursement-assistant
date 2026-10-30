import SwiftUI

public struct ReimburseApp: App {
    @NSApplicationDelegateAdaptor(BackgroundAppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            ReviewView()
                .background(MainWindowAttachment(delegate: appDelegate).frame(width: 0, height: 0))
        }
        Settings { AppSettingsView() }
        MenuBarExtra(AppIdentity.displayName, systemImage: AppIdentity.isVisionTest ? "eye.fill" : "doc.text.image") {
            BackgroundStatusMenu()
        }
    }
}
