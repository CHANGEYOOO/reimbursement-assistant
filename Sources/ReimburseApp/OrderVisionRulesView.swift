import Foundation
import SwiftUI

struct OrderVisionRulesView: View {
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = OrderVisionRulesState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI 识别规则").font(.title2)
            Text("调整订单用途、金额和日期的判断方式。保存后用于新的识别请求；已有结果不会自动重新识别，可使用“重测选中订单”对比。")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $state.text)
                .font(.body)
                .padding(4)
                .border(Color(nsColor: .separatorColor))
                .accessibilityLabel("订单视觉识别规则")
            Text("{{CURRENT_YEAR}} 会自动替换为当前年份。分类选项、结果格式和上传授权由软件保留，编辑规则不会改变这些设置。最多 12,000 字。")
                .font(.caption).foregroundStyle(.secondary)
            if !state.error.isEmpty {
                Text(state.error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("恢复默认规则") { state.confirmingReset = true }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存规则") {
                    do {
                        try AIConfiguration.saveOrderVisionRules(state.text)
                        saved()
                        dismiss()
                    } catch { state.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.text.count > 12_000)
            }
        }
        .padding(24)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 540, idealHeight: 640)
        .confirmationDialog("恢复默认识别规则？", isPresented: $state.confirmingReset, titleVisibility: .visible) {
            Button("恢复默认规则", role: .destructive) {
                AIConfiguration.resetOrderVisionRules()
                state.text = AIConfiguration.orderVisionRules
                state.error = ""
                saved()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将立即保存默认规则，并替换当前编辑内容。已有识别结果保留。")
        }
    }
}

@MainActor private final class OrderVisionRulesState: ObservableObject {
    @Published var text = AIConfiguration.orderVisionRules
    @Published var error = ""
    @Published var confirmingReset = false
}
