import SwiftUI

public struct ReimburseApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup("报销单助手") {
            ReviewView()
        }
    }
}
