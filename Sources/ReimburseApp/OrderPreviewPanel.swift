import SwiftUI

struct OrderPreviewPanel: View {
    let expense: Expense?
    let close: () -> Void

    var body: some View {
        AttachmentSidePreview(
            url: expense?.sourceURL,
            title: expense.map { "第 \($0.number) 笔截图" } ?? "截图预览",
            close: close
        )
    }
}
