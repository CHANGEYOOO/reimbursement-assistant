import Foundation
import SwiftUI

struct AISettingsView: View {
    let close: () -> Void
    let saved: () -> Void
    @StateObject private var state = AISettingsState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 辅助识别设置").font(.title2)
            Toggle("启用 AI 辅助识别", isOn: $state.enabled)
                .disabled(state.testing)
            Text("启用后，用途、金额或日期无法确定的新订单会将本机识别文字发送到当前服务商。截图原图不会上传；金额和日期必须有原文依据，仍需人工核对。")
                .font(.callout).foregroundStyle(.secondary)
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
            Spacer()
            HStack {
                Button(state.testing ? "正在测试…" : "测试连接") { Task { await state.test() } }
                    .disabled(state.testing)
                Text("测试会发送一条固定示例，可能产生少量 API 费用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("关闭", action: close).disabled(state.testing)
                Spacer()
                Button("保存当前配置") { if state.save() { saved() } }
                    .buttonStyle(.borderedProminent).disabled(state.testing)
            }
        }
        .padding(24)
        .frame(width: 620, height: 510)
        .onAppear { state.load() }
        .onChange(of: state.provider) { _, _ in state.load() }
    }
}

@MainActor private final class AISettingsState: ObservableObject {
    @Published var enabled = AIConfiguration.enabled
    @Published var provider = AIConfiguration.provider
    @Published var endpoint = ""
    @Published var model = ""
    @Published var key = ""
    @Published var message = ""
    @Published var testing = false

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
            key = ""
            message = "已保存，当前使用\(provider.title)。"
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
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
