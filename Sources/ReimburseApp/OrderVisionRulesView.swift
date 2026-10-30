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
                    Section("识别原则") {
                        Text("金额采用整笔订单最终实付总额。可食用、饮用的商品归为餐食；不可食用的物品归为道具采购。交通、住宿等按订单内容识别。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Section("日期") {
                        Toggle("没有支付日期时，允许使用下单或创建日期", isOn: $state.preferences.allowOrderDate)
                        Toggle("只有月日时，自动补充当前年份", isOn: $state.preferences.supplementYear)
                    }
                    Section("补充要求") {
                        TextField("例如：用途尽量简短，不必填写商户全名", text: $state.preferences.extraInstructions, axis: .vertical)
                            .lineLimit(3...6)
                        Text("可以用日常语言描述你的习惯，最多4000字。金额实付判断、退款区分和结果校验仍由软件处理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if AIConfiguration.archivedOrderVisionRules != nil {
                        Text("旧版整段规则已保留备份，不再参与识别；当前只使用这里的选项和补充要求。")
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
                        try AIConfiguration.saveOrderVisionSettings(preferences: state.preferences)
                        dismiss()
                    } catch { state.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.preferences.extraInstructions.count > 4000)
            }
        }
        .padding(24)
        .frame(minWidth: 680, idealWidth: 740, minHeight: 600, idealHeight: 720)
        .confirmationDialog("恢复默认识别设置？", isPresented: $state.confirmingReset, titleVisibility: .visible) {
            Button("恢复默认设置", role: .destructive) {
                AIConfiguration.resetOrderVisionSettings()
                state.preferences = AIConfiguration.orderVisionPreferences
                state.error = ""
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将立即恢复推荐选项，并清空补充要求。已有识别结果和旧规则备份保留。")
        }
    }
}

@MainActor private final class OrderVisionRulesState: ObservableObject {
    @Published var preferences = AIConfiguration.orderVisionPreferences
    @Published var error = ""
    @Published var confirmingReset = false
}
