import Foundation
import SwiftUI

struct InvoiceSummaryView: View {
    let orderTotal: Decimal
    let invoiceTotal: Decimal
    let confirmationCount: Int
    let hasUnresolvedAmounts: Bool

    private var difference: Decimal { orderTotal - invoiceTotal }
    private var statusColor: Color {
        orderTotal > 0 && difference <= 0 && confirmationCount == 0 && !hasUnresolvedAmounts ? .green : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 20) {
                metric("已填订单总额", value: money(orderTotal), color: .primary)
                metric("有效发票金额", value: money(invoiceTotal), color: .primary)
                metric((difference > 0 ? "还需补足" : difference < 0 ? "超出金额" : "差额")
                       + (hasUnresolvedAmounts ? "（暂估）" : ""),
                       value: money(abs(difference)), color: statusColor)
                metric("待确认发票", value: "\(confirmationCount) 张", color: confirmationCount > 0 ? .orange : .primary)
            }
            Text(statusText).font(.callout).foregroundStyle(statusColor)
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusText: String {
        if hasUnresolvedAmounts { return "订单金额仍有待处理项，发票差额暂估，处理完成后将自动更新" }
        if orderTotal <= 0 { return "请先录入订单金额" }
        if confirmationCount > 0 {
            return difference > 0 ? "仍有发票待确认，当前已确定金额尚未足额" : "已确定金额已足额，仍有发票待确认"
        }
        return difference > 0 ? "发票金额不足，请补充发票" : "发票金额已足额"
    }

    private func money(_ amount: Decimal) -> String {
        "¥" + amount.formatted(.number.locale(Locale(identifier: "zh_CN"))
            .precision(.fractionLength(2)))
    }

    private func metric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
