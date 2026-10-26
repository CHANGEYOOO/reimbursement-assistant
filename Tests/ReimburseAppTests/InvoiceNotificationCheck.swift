#if DIRECT_TEST_RUNNER
import Foundation

@main struct InvoiceNotificationCheck {
    static func main() {
        let initial = Date(timeIntervalSince1970: 1000)
        precondition(InvoiceNotificationPolicy.isHistorical(since: initial, previousSince: nil))
        precondition(!InvoiceNotificationPolicy.isHistorical(since: initial, previousSince: initial))
        precondition(InvoiceNotificationPolicy.isHistorical(since: initial.addingTimeInterval(-86400), previousSince: initial))
        precondition(!InvoiceNotificationPolicy.isHistorical(since: initial.addingTimeInterval(86400), previousSince: initial))
        precondition(InvoiceNotificationPolicy.text(count: 0, historical: false) == nil)
        precondition(InvoiceNotificationPolicy.text(count: -1, historical: true) == nil)
        let batch = InvoiceNotificationPolicy.text(count: 3, historical: false)!
        precondition(batch.title == "收到 3 张新发票" && batch.body.contains("附件未下载"))
        precondition(InvoiceNotificationPolicy.text(count: 298, historical: true)!.title == "已收集 298 张发票")
        precondition(!batch.body.contains("抬头") && !batch.body.contains("金额"))
        print("Invoice notification policy checks passed; no system permission or notifications requested")
    }
}
#endif
