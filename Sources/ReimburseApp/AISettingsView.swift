import Foundation
import SwiftUI

struct AISettingsView: View {
    let saved: () -> Void
    @StateObject private var state = AISettingsState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI 辅助识别设置").font(.title2)
                Toggle("启用 AI 辅助识别", isOn: $state.enabled)
                    .disabled(state.testing)
                Text("保存并启用后，订单中本地未识别的用途、金额或日期会自动交给 AI，当前待处理记录也会接续处理。仅发送识别文字；月日可按当前年份补全。明确结果直接填写并可导出；日期可自动采用有原文依据的参考日期，金额和用途仍不确定时才需要处理。")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                Toggle("允许发票 AI 兜底上传文字和页面预览", isOn: $state.invoiceFallbackEnabled)
                    .disabled(!state.enabled || state.testing)
                Text("默认关闭。开启并保存后，新导入及已有的待确认附件会自动接续，无需逐张点选；仅本地规则无法判断的发票附件会发送提取文字和页面预览到当前配置的 API，可能包含姓名、税号、账号、地址等个人及企业信息。本地已明确分类的文件不会发送。请使用支持图像输入的模型；不支持时仍保留待确认。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("发票 AI 判断后还需本地复核；证据不足、结果矛盾或调用失败时不会自动确认为发票，也不会删除文件。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(state.clearingInvoiceCache ? "正在清除…" : "清除发票 AI 识别缓存") {
                    Task { await state.clearInvoiceCache() }
                }
                .disabled(state.testing || state.clearingInvoiceCache)
                Text("清除后再次识别可能产生 API 费用；不删除发票文件。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Picker("服务商", selection: $state.provider) {
                    ForEach(AIProvider.allCases) { provider in Text(provider.title).tag(provider) }
                }
                .disabled(state.testing)
                Text("每个服务商独立保存配置，切换前请先保存当前填写。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("完整 API 地址（含 /chat/completions）", text: $state.endpoint)
                    .textFieldStyle(.roundedBorder)
                    .disabled(state.testing)
                TextField("模型名称", text: $state.model).textFieldStyle(.roundedBorder).disabled(state.testing)
                SecureField("API Key（留空保留该服务商已保存的密钥）", text: $state.key)
                    .textFieldStyle(.roundedBorder)
                    .disabled(state.testing)
                Text("密钥保存在 Mac 钥匙串。阿里百炼地址需与密钥地域一致，也可填写业务空间专属地址。")
                    .font(.caption).foregroundStyle(.secondary)
                if !state.message.isEmpty { Text(state.message).font(.callout).textSelection(.enabled) }
                HStack {
                    Button(state.testing ? "正在测试…" : "测试连接") { Task { await state.test() } }
                        .disabled(state.testing)
                    Text("测试仅验证文字连接；发票需支持图像输入的模型。测试可能产生少量 API 费用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("保存当前配置") { if state.save() { saved() } }
                        .buttonStyle(.borderedProminent).disabled(state.testing)
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 510)
        .onChange(of: state.provider) { _, _ in state.load() }
    }
}

@MainActor private final class AISettingsState: ObservableObject {
    @Published var enabled = AIConfiguration.enabled
    @Published var invoiceFallbackEnabled = AIConfiguration.invoiceFallbackEnabled
    @Published var provider = AIConfiguration.provider
    @Published var endpoint = ""
    @Published var model = ""
    @Published var key = ""
    @Published var message = ""
    @Published var testing = false
    @Published var clearingInvoiceCache = false

    init() { load() }

    func load() {
        let profile = AIConfiguration.profile(for: provider)
        endpoint = profile.endpoint
        model = profile.model
        key = ""
        message = ""
    }

    private func requestConfiguration() throws -> AIRequestConfiguration {
        let apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? try AIConfiguration.apiKey(for: provider) : key
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "AISettings", code: 1, userInfo: [NSLocalizedDescriptionKey: "请填写有效的 HTTPS 接口地址。"])
        }
        return try AIRequestConfiguration(endpoint: url, model: model, apiKey: apiKey)
    }

    func save() -> Bool {
        do {
            if enabled { _ = try requestConfiguration() }
            try AIConfiguration.save(profile: AIProfile(endpoint: endpoint, model: model), apiKey: key, provider: provider)
            AIConfiguration.provider = provider
            AIConfiguration.enabled = enabled
            AIConfiguration.invoiceFallbackEnabled = invoiceFallbackEnabled
            key = ""
            message = "已保存，当前使用\(provider.title)。"
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func clearInvoiceCache() async {
        clearingInvoiceCache = true
        defer { clearingInvoiceCache = false }
        do {
            try await InvoiceAIService.shared.clearCache()
            message = "发票 AI 识别缓存已清除；发票文件已保留。"
        } catch { message = error.localizedDescription }
    }

    func test() async {
        testing = true
        defer { testing = false }
        do {
            let configuration = try requestConfiguration()
            let result = try await SemanticClassifier.classify(text: "连接测试：出租车车费已支付。", configuration: configuration)
            message = "连接成功，返回分类：\(result.category.rawValue)。如需启用，请保存当前配置。"
        } catch { message = error.localizedDescription }
    }
}
