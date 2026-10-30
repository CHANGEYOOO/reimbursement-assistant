#if DIRECT_TEST_RUNNER
import Foundation

@main struct AppIdentityCheck {
    static func main() {
        #if REIMBURSE_VISION_TEST
        precondition(AppIdentity.isVisionTest)
        precondition(AppIdentity.displayName == "报销单助手·视觉测试")
        precondition(AppIdentity.bundleIdentifier == "top.kjoe.ReimburseMacApp.vision-test")
        precondition(AppIdentity.supportFolderName == "报销单助手-视觉测试")
        precondition(AppIdentity.keychainService("ai") == "top.kjoe.ReimburseMacApp.vision-test.ai")
        precondition(AppIdentity.keychainService("qqmail") == "top.kjoe.ReimburseMacApp.vision-test.qqmail")
        #else
        precondition(!AppIdentity.isVisionTest)
        precondition(AppIdentity.displayName == "报销单助手")
        precondition(AppIdentity.bundleIdentifier == "top.kjoe.ReimburseMacApp")
        precondition(AppIdentity.supportFolderName == "报销单助手")
        precondition(AppIdentity.keychainService("ai") == "top.kjoe.ReimburseMacApp.ai")
        precondition(AppIdentity.keychainService("qqmail") == "top.kjoe.ReimburseMacApp.qqmail")
        #endif
        precondition(AppIdentity.supportDirectory.lastPathComponent == AppIdentity.supportFolderName)
        precondition(AppIdentity.supportDirectory.deletingLastPathComponent().lastPathComponent == "Application Support")
        print("App identity, data root and credential namespaces passed (\(AppIdentity.displayName))")
    }
}

#endif
