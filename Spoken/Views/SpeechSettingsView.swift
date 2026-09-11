import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

struct SpeechSettingsDependencies {
    var defaults: UserDefaults
    var readKey: () throws -> String?
    var saveKey: (String) -> Bool
    var refreshConnection: (SpeechRecognitionProvider) -> Void
    var providers: () -> [(id: String, name: String)]
    var metrics: () -> ASRMetricsSnapshot
    var latency: () -> [String: PipelineLatencyMetrics.Distribution]

    static var live: Self {
        Self(defaults: .standard, readKey: { try SecureKeyStorage.shared.readSpeechCredential() },
             saveKey: { SecureKeyStorage.shared.saveSpeechAPIKey($0) }, refreshConnection: { provider in
                CloudSpeechService.shared.disconnect()
                if provider == .cloud || provider == .auto { SpeechService.shared.prepareCloudConnection() }
             }, providers: { CloudSpeechService.shared.availableProviders() },
             metrics: { ASRStabilityMetrics.shared.snapshot() }, latency: { PipelineLatencyMetrics.shared.distributions() })
    }
}

// MARK: - 语音识别设置

struct SpeechConfigSectionView: View {
    let navigation: SettingsNavigationGuard
    let dependencies: SpeechSettingsDependencies
    @State private var originalDraft: [String] = []
    @State private var saveError: String?
    @State private var keyLoadFailed = false
    private var currentDraft: [String] { [provider.rawValue, cloudProviderId, apiKey, modelName, workspaceID] }
    @State private var provider: SpeechRecognitionProvider = .local
    @State private var cloudProviderId: String = "dashscope"
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var workspaceID: String = ""
    @State private var saved: Bool = false
    @State private var metrics = ASRMetricsSnapshot(sessions: 0, connected: 0, successes: 0, failures: 0, reconnects: 0, fallbacks: 0)
    @State private var latencyMetrics: [String: PipelineLatencyMetrics.Distribution] = [:]

    init(navigation: SettingsNavigationGuard, dependencies: SpeechSettingsDependencies = .live) {
        self.navigation = navigation
        self.dependencies = dependencies
    }

    private let textPrimary = Color.primary
    private let textMuted = Color.secondary

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 识别引擎选择
                VStack(alignment: .leading, spacing: 8) {
                    Text("识别引擎")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(textPrimary)
                    Text("选择语音识别方式")
                        .font(.system(size: 11))
                        .foregroundColor(textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 引擎选择器
                FlowLayout(spacing: 8) {
                    ForEach(SpeechRecognitionProvider.allCases, id: \.rawValue) { p in
                        Button(action: {
                            provider = p
                        }) {
                            Text(p.rawValue)
                                .font(.system(size: 11, weight: provider == p ? .medium : .regular))
                                .foregroundColor(provider == p ? SpokenTheme.selectedText : textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(provider == p ? SpokenTheme.accent : SpokenTheme.inset)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 云端 Provider 选择
                if provider == .cloud || provider == .auto {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("云端服务")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(textPrimary)
                        Text("选择云端语音识别服务提供商")
                            .font(.system(size: 11))
                            .foregroundColor(textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    FlowLayout(spacing: 8) {
                        ForEach(availableCloudProviders(), id: \.id) { p in
                            Button(action: {
                                cloudProviderId = p.id
                            }) {
                                Text(p.name)
                                    .font(.system(size: 11, weight: cloudProviderId == p.id ? .medium : .regular))
                                    .foregroundColor(cloudProviderId == p.id ? SpokenTheme.selectedText : textPrimary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(cloudProviderId == p.id ? SpokenTheme.accent : SpokenTheme.inset)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("云端模型")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(textPrimary)
                        TextField(defaultModelPlaceholder(), text: $modelName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    if cloudProviderId == "qwen-realtime" {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("业务空间ID（推荐）")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(textPrimary)
                            TextField("留空时使用DashScope公共域名", text: $workspaceID)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            Text("填写后使用北京地域业务空间专属域名，提高实时识别连接稳定性。")
                                .font(.system(size: 10))
                                .foregroundColor(textMuted)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(textPrimary)
                        SecureField("sk-...", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .accessibilityLabel("语音识别 API Key")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("稳定性记录")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button("刷新") {
                                metrics = dependencies.metrics()
                                latencyMetrics = dependencies.latency()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundColor(SpokenTheme.accent)
                        }
                        Text("会话 \(metrics.sessions) · 成功 \(metrics.successes) · 失败 \(metrics.failures) · 重连 \(metrics.reconnects) · 本地降级 \(metrics.fallbacks)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(textMuted)
                        if metrics.successes + metrics.failures > 0 {
                            Text(String(format: "云端完成率 %.1f%%", metrics.successRate * 100))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(metrics.successRate >= 0.995 ? .green : .orange)
                        }
                        if !latencyMetrics.isEmpty {
                            Divider()
                            latencyRow("首字", key: "hotkey_to_first_text")
                            latencyRow("ASR收尾", key: "stop_to_asr_final")
                            latencyRow("AI处理", key: "ai_request_to_complete")
                            latencyRow("结束到写入", key: "stop_to_injection")
                        }
                        Text("仅保存在本机，不记录音频和转录正文。")
                            .font(.system(size: 10))
                            .foregroundColor(textMuted)
                    }
                    .padding(10)
                    .background(SpokenTheme.inset)
                    .cornerRadius(8)
                }

                SettingsFeedback(error: saveError)
                if keyLoadFailed { Button("重试读取密钥", action: retryKey) }

                // 保存状态
                if saved {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                        Text("已保存")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Spacer()
                    Button("保存") {
                        do { try saveConfig() } catch { saveError = error.localizedDescription }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(SpokenTheme.accent)
                    .foregroundColor(SpokenTheme.selectedText)
                    .cornerRadius(8)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(keyLoadFailed)
                }
            }
        }
        .onAppear {
            loadConfig()
            navigation.install(isDirty: { currentDraft != originalDraft }, save: saveConfig, discard: loadConfig)
            metrics = dependencies.metrics()
            latencyMetrics = dependencies.latency()
        }
        .onChange(of: currentDraft) { _, _ in saved = false }
    }

    @ViewBuilder
    private func latencyRow(_ label: String, key: String) -> some View {
        if let distribution = latencyMetrics[key] {
            Text("\(label) P50 \(milliseconds(distribution.p50))ms · P90 \(milliseconds(distribution.p90))ms · P95 \(milliseconds(distribution.p95))ms · n=\(distribution.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(textMuted)
        }
    }

    private func milliseconds(_ seconds: Double) -> Int {
        Int((seconds * 1_000).rounded())
    }

    private func availableCloudProviders() -> [(id: String, name: String)] {
        dependencies.providers()
    }

    private func defaultModelPlaceholder() -> String {
        switch cloudProviderId {
        case "qwen-realtime":
            return "qwen3-asr-flash-realtime"
        default:
            return "fun-asr-flash-8k-realtime"
        }
    }

    private func loadConfig() {
        let rawValue = dependencies.defaults.string(forKey: "speechRecognitionProvider") ?? SpeechRecognitionProvider.local.rawValue
        provider = SpeechRecognitionProvider(rawValue: rawValue) ?? .local
        cloudProviderId = dependencies.defaults.string(forKey: "cloud_speech_provider") ?? "qwen-realtime"
        modelName = dependencies.defaults.string(forKey: "speech_model_name") ?? defaultModelPlaceholder()
        workspaceID = dependencies.defaults.string(forKey: "speech_workspace_id") ?? ""
        apiKey = ""
        retryKey()
        originalDraft = currentDraft
    }

    private func retryKey() {
        do {
            apiKey = try dependencies.readKey() ?? ""
            // Only the key baseline changes; other unsaved fields remain dirty.
            if originalDraft.indices.contains(2) { originalDraft[2] = apiKey }
            keyLoadFailed = false; saveError = nil
        } catch { keyLoadFailed = true; saveError = error.localizedDescription }
    }

    private func saveConfig() throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyLoadFailed else {
            throw ConfigurationError.unavailable("密钥读取失败，请先重试读取，避免覆盖原有密钥")
        }
        guard dependencies.saveKey(trimmedKey) else {
            throw ConfigurationError.unavailable("语音识别密钥未保存，请解锁钥匙串后重试")
        }
        dependencies.defaults.set(provider.rawValue, forKey: "speechRecognitionProvider")
        dependencies.defaults.set(cloudProviderId, forKey: "cloud_speech_provider")
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        dependencies.defaults.set(model.isEmpty ? defaultModelPlaceholder() : model, forKey: "speech_model_name")
        let trimmedWorkspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if QwenEndpointResolver.normalizedWorkspaceID(trimmedWorkspaceID) != nil {
            dependencies.defaults.set(trimmedWorkspaceID, forKey: "speech_workspace_id")
        } else {
            dependencies.defaults.removeObject(forKey: "speech_workspace_id")
            workspaceID = ""
        }
        dependencies.refreshConnection(provider)
        originalDraft = currentDraft
        saveError = nil
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            saved = false
        }
    }
}

// MARK: - 颜色扩展

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
