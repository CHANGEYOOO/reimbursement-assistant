import Foundation

/// A separately installed test build must not reuse the production files or credentials.
enum AppIdentity {
    #if REIMBURSE_VISION_TEST
    static let isVisionTest = true
    static let displayName = "报销单助手·视觉测试"
    static let bundleIdentifier = "top.kjoe.ReimburseMacApp.vision-test"
    static let supportFolderName = "报销单助手-视觉测试"
    #else
    static let isVisionTest = false
    static let displayName = "报销单助手"
    static let bundleIdentifier = "top.kjoe.ReimburseMacApp"
    static let supportFolderName = "报销单助手"
    #endif

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(supportFolderName, isDirectory: true)
    }

    static func keychainService(_ suffix: String) -> String { bundleIdentifier + "." + suffix }
}
