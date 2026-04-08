import SwiftUI
import CoreGraphics

enum SpokenMode: String, CaseIterable {
    case text = "文本优化"
    case prompt = "Prompt"
}

struct ContentView: View {
    @State private var mode: SpokenMode = .text
    @State private var isRecording = false
    @State private var isProcessing = false
    @State private var statusMessage = "就绪"
    @State private var frontmostApp: NSRunningApplication?
    @State private var buttonScale: CGFloat = 1.0

    // ElevenLabs Warm Palette
    private let bgPrimary = Color(hex: "#ffffff")
    private let bgSecondary = Color(hex: "#f5f5f5")
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
            .padding(.bottom, 10)

            // 模式切换 - ElevenLabs 胶囊风格
            HStack(spacing: 6) {
                ForEach(SpokenMode.allCases, id: \.self) { m in
                    Button(action: { mode = m }) {
                        Text(m.rawValue)
                            .font(.system(size: 12, weight: mode == m ? .semibold : .regular))
                            .tracking(mode == m ? 0.3 : 0.14)
                            .foregroundColor(mode == m ? .white : textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                mode == m
                                    ? AnyShapeStyle(textPrimary)
                                    : AnyShapeStyle(warmStone)
                            )
                            .cornerRadius(9999)  // ElevenLabs pill style
                            .shadow(color: Color(hex: "#4e3220").opacity(mode == m ? 0.12 : 0), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            Spacer().frame(height: 16)

            // 中心录音按钮 - ElevenLabs floating style
            RecordButton(
                isRecording: isRecording,
                isProcessing: isProcessing,
                scale: buttonScale,
                warmStone: warmStone,
                textPrimary: textPrimary,
                textMuted: textMuted,
                onTap: toggleRecording
            )

            Spacer().frame(height: 12)

            // 状态文字
            Text(statusMessage)
                .font(.system(size: 13, weight: .regular))
                .tracking(0.16)
                .foregroundColor(statusColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .animation(.easeInOut(duration: 0.2), value: statusMessage)

            // 权限入口
            if statusMessage == "请授权辅助功能权限" || statusMessage == "请授权麦克风权限" {
                Button(action: {
                    AccessibilityService.shared.openAccessibilityPreferences()
                }) {
                    Text("打开系统设置")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.14)
                        .foregroundColor(accentBlue)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            Spacer().frame(height: 14)
        }
        .frame(width: 260, height: 200)
        .background(
            bgPrimary
                .shadow(color: Color(hex: "#000000").opacity(0.04), radius: 4, x: 0, y: 2)
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
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
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
        withAnimation(.easeInOut(duration: 0.15)) {
            buttonScale = 0.94
        }

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
                    self.optimizeAndInput(transcript)
                }
            }
        )
    }

    private func stopRecording() {
        statusMessage = "正在识别..."
        withAnimation(.easeInOut(duration: 0.15)) {
            buttonScale = 1.0
        }
        WhisperService.shared.stopRecording()
    }

    private func optimizeAndInput(_ transcript: String) {
        guard !transcript.isEmpty else {
            statusMessage = "未识别到内容"
            return
        }

        isProcessing = true
        statusMessage = "AI 优化中..."

        MiniMaxService.shared.optimize(text: transcript, mode: mode) { [self] result in
            DispatchQueue.main.async {
                self.isProcessing = false

                let finalText: String
                switch result {
                case .success(let optimized):
                    finalText = optimized.isEmpty ? transcript : optimized
                case .failure(let error):
                    print("Spoken: [ERROR] MiniMax failed: \(error.localizedDescription)")
                    finalText = transcript
                }

                if let app = self.frontmostApp {
                    app.activate(options: .activateIgnoringOtherApps)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        let success = KeyboardService.shared.typeText(finalText)
                        self.statusMessage = success ? "已输入 ✓" : "输入失败 ✗"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.statusMessage = "就绪"
                        }
                    }
                } else {
                    let success = KeyboardService.shared.typeText(finalText)
                    self.statusMessage = success ? "已输入 ✓" : "输入失败 ✗"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.statusMessage = "就绪"
                    }
                }
            }
        }
    }
}

// MARK: - 录音按钮（ElevenLabs 风格）

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
                // 外层 pill 背景 - ElevenLabs 胶囊按钮风格
                Capsule()
                    .fill(warmStone)
                    .frame(width: 80, height: 80)
                    .shadow(
                        color: Color(hex: "#4e3220").opacity(0.08),
                        radius: 6,
                        x: 0,
                        y: 3
                    )
                    .shadow(
                        color: Color(hex: "#000000").opacity(0.04),
                        radius: 1,
                        x: 0,
                        y: 0
                    )

                // 录音中红色脉冲
                if isRecording {
                    Capsule()
                        .fill(Color(hex: "#c0392b").opacity(0.12))
                        .frame(width: 80, height: 80)
                        .scaleEffect(pulseScale)
                        .animation(
                            .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                            value: pulseScale
                        )
                        .onAppear { pulseScale = 1.15 }
                }

                // 中心图标
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
