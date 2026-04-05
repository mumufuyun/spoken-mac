import SwiftUI

enum SpokenMode: String, CaseIterable {
    case text = "文本优化"
    case prompt = "Prompt"
}

struct ContentView: View {
    @State private var mode: SpokenMode = .text
    @State private var isRecording = false
    @State private var isProcessing = false
    @State private var statusMessage = "就绪"

    var body: some View {
        VStack(spacing: 0) {
            // 模式切换
            HStack(spacing: 8) {
                ForEach(SpokenMode.allCases, id: \.self) { m in
                    Button(action: { mode = m }) {
                        Text(m.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(mode == m ? Color(hex: "#4F7DF3") : Color(hex: "#F0F2F5"))
                            .foregroundColor(mode == m ? .white : Color(hex: "#6B7280"))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)

            // 主按钮
            Button(action: toggleRecording) {
                VStack(spacing: 8) {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("优化中...")
                            .font(.system(size: 13, weight: .medium))
                    } else if isRecording {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 24))
                        Text("说话中...")
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 24))
                        Text("开始说话")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(
                    isRecording
                        ? AnyShapeStyle(Color.red)
                        : AnyShapeStyle(LinearGradient(
                            colors: [Color(hex: "#4F7DF3"), Color(hex: "#6B5CE7")],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                )
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)
            .padding(.horizontal, 16)

            // 状态提示
            if !isRecording && !isProcessing {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
            }

            Spacer().frame(height: 12)
        }
        .frame(width: 240, height: 160)
        .onAppear(perform: checkPermissions)
    }

    // MARK: - Actions

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func checkPermissions() {
        SpeechService.shared.requestPermissions { micGranted, speechGranted in
            DispatchQueue.main.async {
                statusMessage = (micGranted && speechGranted) ? "就绪" : "请授权权限"
            }
        }
    }

    private func startRecording() {
        isRecording = true
        statusMessage = "正在说话..."

        SpeechService.shared.startRecording(
            onPartial: { [self] text in
                DispatchQueue.main.async {
                    self.statusMessage = text.isEmpty ? "正在说话..." : text
                }
            },
            onFinal: { [self] transcript in
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.optimizeAndInput(transcript)
                }
            }
        )
    }

    private func stopRecording() {
        SpeechService.shared.stopRecording()
        isRecording = false
        statusMessage = "正在识别..."
    }

    private func optimizeAndInput(_ transcript: String) {
        guard !transcript.isEmpty else {
            statusMessage = "未识别到内容"
            return
        }

        // TODO: MiniMax 暂时跳过，直接用原始文字
        isProcessing = false
        statusMessage = "已输入"
        KeyboardService.shared.typeText(transcript)
    }
}
