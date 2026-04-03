import SwiftUI

enum SpokenMode: String, CaseIterable {
    case text = "文本"
    case prompt = "Prompt"
}

struct ContentView: View {
    @State private var mode: SpokenMode = .text
    @State private var isRecording = false
    @State private var isProcessing = false
    @State private var lastResult = ""
    @State private var statusMessage = "就绪"
    @State private var hasPermission = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: isRecording ? statusColor.opacity(0.5) : .clear, radius: 4)

                Text("Spoken")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))

                Spacer()

                Text(statusMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 16)

            // Mode Picker
            HStack(spacing: 8) {
                ForEach(SpokenMode.allCases, id: \.self) { m in
                    Button(action: { mode = m }) {
                        Text(m.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(mode == m ? Color(hex: "#4F7DF3") : Color(hex: "#F0F2F5"))
                            .foregroundColor(mode == m ? .white : Color(hex: "#6B7280"))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .disabled(isRecording || isProcessing)

            Spacer()

            // Partial result preview
            if !lastResult.isEmpty {
                Text(lastResult)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }

            // Main Button
            Button(action: toggleRecording) {
                HStack(spacing: 8) {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("优化中")
                            .font(.system(size: 14, weight: .medium))
                    } else if isRecording {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13))
                        Text("停止")
                            .font(.system(size: 14, weight: .medium))
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13))
                        Text("开始说话")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
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
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 300, height: 200)
        .onAppear(perform: checkPermissions)
    }

    // MARK: - Computed

    private var statusColor: Color {
        if isRecording { return .red }
        if isProcessing { return .orange }
        return Color(hex: "#4F7DF3")
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
                hasPermission = micGranted && speechGranted
                statusMessage = hasPermission ? "就绪" : "请授权权限"
            }
        }
    }

    private func startRecording() {
        isRecording = true
        statusMessage = "正在说话..."
        lastResult = ""

        SpeechService.shared.startRecording(
            onPartial: { [self] text in
                DispatchQueue.main.async {
                    self.lastResult = text
                    self.statusMessage = text.isEmpty ? "正在说话..." : text
                }
            },
            onFinal: { [self] transcript in
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.lastResult = ""
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

        isProcessing = true
        statusMessage = "优化中..."

        MiniMaxService.shared.optimize(text: transcript, mode: mode) { result in
            DispatchQueue.main.async {
                self.isProcessing = false

                switch result {
                case .success(let optimizedText):
                    self.statusMessage = "已输入"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        KeyboardService.shared.typeText(optimizedText)
                        NotificationService.shared.notifySuccess(text: optimizedText)
                    }
                case .failure(let error):
                    self.statusMessage = "优化失败"
                    NotificationService.shared.notifyFailure(reason: error.localizedDescription)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        KeyboardService.shared.typeText(transcript)
                    }
                }
            }
        }
    }
}

