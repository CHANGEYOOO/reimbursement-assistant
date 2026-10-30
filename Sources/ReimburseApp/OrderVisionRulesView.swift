import Foundation
import SwiftUI

struct OrderVisionRulesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = OrderVisionRulesState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI 识别偏好").font(.title2)
            Text("按你的报销习惯调整即可，基础识别规则由软件维护。保存后用于后续识别，已有记录不会自动重跑。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Form {
                    Section("用途") {
                        Picker("填写方式", selection: $state.preferences.purposeStyle) {
                            ForEach(OrderVisionPreferences.PurposeStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        Text(state.preferences.purposeStyle == .short
                             ? "例如：停车费、便利店消费、场地定金。"
                             : "例如：某便利店消费、某酒店住宿。没有商品信息时不猜测买了什么。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("分类") {
                        Text("可食用、饮用的商品归为餐食；不可食用的物品归为道具采购。交通、住宿等按订单内容识别。")
                            .font(.callout).foregroundStyle(.secondary)
                        TextField("分类补充偏好（选填）", text: $state.preferences.classificationNote, axis: .vertical)
                            .lineLimit(2...4)
                        Text("例如：拍摄使用的设备租赁归为其他。最多1000字。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("日期") {
                        Toggle("没有支付日期时，允许使用下单或创建日期", isOn: $state.preferences.allowOrderDate)
                        Toggle("只有月日时，自动补充当前年份", isOn: $state.preferences.supplementYear)
                    }
                    Section("补充要求") {
                        TextField("例如：用途尽量简短，不必填写商户全名", text: $state.preferences.extraInstructions, axis: .vertical)
                            .lineLimit(3...6)
                        Text("可以用日常语言描述你的习惯，最多2000字。金额实付判断、退款区分和结果校验仍由软件处理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("高级设置", isExpanded: $state.showingAdvanced) {
                        Text("已有的自定义规则保留在这里。通常无需修改；上方偏好优先于基础业务规则，结果格式和上传授权由软件保留。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $state.advancedRules)
                            .font(.body)
                            .frame(minHeight: 220)
                            .padding(4)
                            .border(Color(nsColor: .separatorColor))
                            .accessibilityLabel("高级订单识别规则")
                        Text("最多12000字；{{CURRENT_YEAR}} 会替换为当前年份。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            if !state.error.isEmpty {
                Text(state.error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("恢复默认设置") { state.confirmingReset = true }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存偏好") {
                    do {
                        try AIConfiguration.saveOrderVisionSettings(preferences: state.preferences, advancedRules: state.advancedRules)
                        dismiss()
                    } catch { state.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.advancedRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.advancedRules.count > 12_000
                          || state.preferences.classificationNote.count > 1000 || state.preferences.extraInstructions.count > 2000)
            }
        }
        .padding(24)
        .frame(minWidth: 680, idealWidth: 740, minHeight: 600, idealHeight: 720)
        .confirmationDialog("恢复默认识别设置？", isPresented: $state.confirmingReset, titleVisibility: .visible) {
            Button("恢复默认设置", role: .destructive) {
                AIConfiguration.resetOrderVisionSettings()
                state.preferences = AIConfiguration.orderVisionPreferences
                state.advancedRules = AIConfiguration.orderVisionRules
                state.error = ""
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将立即恢复推荐偏好，并清除补充要求及高级自定义规则。已有识别结果保留。")
        }
    }
}

@MainActor private final class OrderVisionRulesState: ObservableObject {
    @Published var preferences = AIConfiguration.orderVisionPreferences
    @Published var advancedRules = AIConfiguration.orderVisionRules
    @Published var showingAdvanced = false
    @Published var error = ""
    @Published var confirmingReset = false
}
