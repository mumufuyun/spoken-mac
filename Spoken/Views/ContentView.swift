import SwiftUI
import CoreGraphics

enum SpokenMode: String, CaseIterable {
    case direct = "直接输入"
    case polish = "润色"
    case prompt = "Prompt"
    case translate = "翻译"
    case summarize = "摘要"
    case format = "格式化"
}

enum TranslateLanguage: String, CaseIterable {
    case english = "英文"
    case japanese = "日文"
    case korean = "韩文"
}

struct ContentView: View {
    @State private var mode: SpokenMode = .direct
    @State private var translateLang: TranslateLanguage = .english
    @State private var isRecording = false
    @State private var isProcessing = false
    @State private var statusMessage = "就绪"
    @State private var frontmostApp: NSRunningApplication?
    @State private var buttonScale: CGFloat = 1.0

    // ElevenLabs Warm Palette
    private let warmStone = Color(hex: "#f5f2ef")
    private let textPrimary = Color(hex: "#000000")
    private let textSecondary = Color(hex: "#4e4e4e")
    private let textMuted = Color(hex: "#777169")
    private let accentBlue = Color(hex: "#4a90d9")

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("Spoken")
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundColor(textSecondary)
                    .tracking(0.14)
                Spacer()
                Text("⌥;")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // 模式切换 - 6模式分两行
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    ForEach([SpokenMode.direct, .polish, .prompt], id: \.self) { m in
                        ModeButton(mode: m, current: $mode)
                    }
                }
                HStack(spacing: 5) {
                    ForEach([SpokenMode.translate, .summarize, .format], id: \.self) { m in
                        ModeButton(mode: m, current: $mode)
                    }
                }
            }
            .padding(.horizontal, 12)

            // 翻译语言选择（翻译模式下显示）
            if mode == .translate {
                HStack(spacing: 8) {
                    Text("目标语言：")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(textMuted)
                    ForEach(TranslateLanguage.allCases, id: \.self) { lang in
                        Button(action: { translateLang = lang }) {
                            Text(lang.rawValue)
                                .font(.system(size: 11, weight: translateLang == lang ? .medium : .regular))
                                .foregroundColor(translateLang == lang ? .white : textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(translateLang == lang ? accentBlue : warmStone)
                                .cornerRadius(9999)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            Spacer().frame(height: 14)

            // 中心录音按钮
            RecordButton(
                isRecording: isRecording,
                isProcessing: isProcessing,
                scale: buttonScale,
                warmStone: warmStone,
                textPrimary: textPrimary,
                textMuted: textMuted,
                onTap: toggleRecording
            )

            Spacer().frame(height: 10)

            // 状态文字
            Text(statusMessage)
                .font(.system(size: 12, weight: .regular))
                .tracking(0.16)
                .foregroundColor(statusColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)

            // 权限入口
            if statusMessage == "请授权辅助功能权限" || statusMessage == "请授权麦克风权限" {
                Button(action: {
                    AccessibilityService.shared.openAccessibilityPreferences()
                }) {
                    Text("打开系统设置")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accentBlue)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            Spacer().frame(height: 12)
        }
        .frame(width: 260, height: mode == .translate ? 240 : 220)
        .background(
            Color.white
                .shadow(color: Color(hex: "#4e3220").opacity(0.04), radius: 4, x: 0, y: 2)
                .shadow(color: Color(hex: "#000000").opacity(0.02), radius: 1, x: 0, y: 0)
        )
        .onAppear(perform: checkPermissions)
    }

    private var statusColor: Color {
        if isProcessing { return textMuted }
        if isRecording { return Color(hex: "#c0392b") }
        if statusMessage == "已输入 ✓" { return Color(hex: "#1f8a65") }
        if statusMessage.contains("失败") || statusMessage.contains("错误") { return Color(hex: "#cf2d56") }
        return textMuted
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func checkPermissions() {
        WhisperService.shared.requestPermissions { micGranted in
            let accessibilityGranted = AccessibilityService.shared.isAccessibilityEnabled()
            DispatchQueue.main.async {
                if !micGranted {
                    self.statusMessage = "请授权麦克风权限"
                } else if !accessibilityGranted {
                    self.statusMessage = "请授权辅助功能权限"
                } else {
                    self.statusMessage = "就绪"
                }
            }
        }
    }

    private func startRecording() {
        frontmostApp = NSWorkspace.shared.frontmostApplication
        isRecording = true
        statusMessage = "正在说话..."
        withAnimation(.easeInOut(duration: 0.15)) { buttonScale = 0.94 }

        WhisperService.shared.startRecording(
            onPartial: { [self] text in
                DispatchQueue.main.async {
                    self.statusMessage = text.isEmpty ? "正在说话..." : text
                }
            },
            onFinal: { [self] transcript in
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.buttonScale = 1.0
                    self.processAndInput(transcript)
                }
            }
        )
    }

    private func stopRecording() {
        statusMessage = "正在识别..."
        withAnimation(.easeInOut(duration: 0.15)) { buttonScale = 1.0 }
        WhisperService.shared.stopRecording()
    }

    private func processAndInput(_ transcript: String) {
        guard !transcript.isEmpty else {
            statusMessage = "未识别到内容"
            return
        }

        // 直接输入模式：不做任何 AI 处理
        if mode == .direct {
            injectText(transcript)
            return
        }

        // AI 处理模式
        isProcessing = true
        statusMessage = mode == .polish ? "润色中..." :
                        mode == .prompt ? "生成 Prompt..." :
                        mode == .translate ? "翻译中..." :
                        mode == .summarize ? "摘要中..." : "格式化中..."

        MiniMaxService.shared.process(
            text: transcript,
            mode: mode,
            translateLang: translateLang
        ) { [self] result in
            DispatchQueue.main.async {
                self.isProcessing = false
                let finalText: String
                switch result {
                case .success(let output):
                    finalText = output.isEmpty ? transcript : output
                case .failure(let error):
                    print("Spoken: [ERROR] MiniMax failed: \(error.localizedDescription)")
                    finalText = transcript
                }
                self.injectText(finalText)
            }
        }
    }

    private func injectText(_ text: String) {
        if let app = frontmostApp {
            app.activate(options: .activateIgnoringOtherApps)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let success = KeyboardService.shared.typeText(text)
                self.statusMessage = success ? "已输入 ✓" : "输入失败 ✗"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.statusMessage = "就绪"
                }
            }
        } else {
            let success = KeyboardService.shared.typeText(text)
            statusMessage = success ? "已输入 ✓" : "输入失败 ✗"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.statusMessage = "就绪"
            }
        }
    }
}

// MARK: - 模式按钮

struct ModeButton: View {
    let mode: SpokenMode
    @Binding var current: SpokenMode

    private let warmStone = Color(hex: "#f5f2ef")
    private let textPrimary = Color(hex: "#000000")
    private let textSecondary = Color(hex: "#4e4e4e")

    var body: some View {
        Button(action: { current = mode }) {
            Text(mode.rawValue)
                .font(.system(size: 11, weight: current == mode ? .semibold : .regular))
                .tracking(current == mode ? 0.3 : 0.14)
                .foregroundColor(current == mode ? .white : textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(current == mode ? textPrimary : warmStone)
                .cornerRadius(9999)
                .shadow(
                    color: Color(hex: "#4e3220").opacity(current == mode ? 0.12 : 0),
                    radius: 3, x: 0, y: 1
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 录音按钮

struct RecordButton: View {
    let isRecording: Bool
    let isProcessing: Bool
    let scale: CGFloat
    let warmStone: Color
    let textPrimary: Color
    let textMuted: Color
    let onTap: () -> Void

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Capsule()
                    .fill(warmStone)
                    .frame(width: 76, height: 76)
                    .shadow(color: Color(hex: "#4e3220").opacity(0.08), radius: 6, x: 0, y: 3)

                if isRecording {
                    Capsule()
                        .fill(Color(hex: "#c0392b").opacity(0.12))
                        .frame(width: 76, height: 76)
                        .scaleEffect(pulseScale)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulseScale)
                        .onAppear { pulseScale = 1.15 }
                }

                Group {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: textMuted))
                            .scaleEffect(0.9)
                    } else if isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: "#c0392b"))
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22))
                            .foregroundColor(textPrimary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .disabled(isProcessing)
    }
}
