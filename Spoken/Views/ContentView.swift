import SwiftUI

enum SpokenMode: String, CaseIterable {
    case text = "文本模式"
    case prompt = "Prompt模式"
}

struct ContentView: View {
    @State private var mode: SpokenMode = .text
    @State private var isRecording = false
    @State private var isProcessing = false
    @State private var lastResult = ""
    @State private var statusMessage = "点击开始说话"
    @State private var hasPermission = false

    var body: some View {
        VStack(spacing: 10) {
            // Header
            HStack {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                    .font(.title2)

                Text("Spoken")
                    .font(.headline)

                Spacer()

                Text(mode.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider()

            // Mode Picker
            Picker("模式", selection: $mode) {
                ForEach(SpokenMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .disabled(isRecording || isProcessing)

            // Main Button
            Button(action: toggleRecording) {
                HStack {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.8)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: buttonIcon)
                    }
                    Text(buttonTitle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(buttonColor)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .disabled(isProcessing)
            .padding(.horizontal, 16)

            // Result / Status
            if !lastResult.isEmpty {
                Text(lastResult)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
            }

            Text(statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
        }
        .frame(width: 300, height: 180)
        .onAppear(perform: checkPermissions)
    }

    // MARK: - Computed Properties

    private var buttonIcon: String {
        if isRecording { return "stop.fill" }
        if isProcessing { return "arrow.triangle.2.circlepath" }
        return "mic.fill"
    }

    private var buttonTitle: String {
        if isRecording { return "停止" }
        if isProcessing { return "优化中..." }
        return "开始说话"
    }

    private var buttonColor: Color {
        if isRecording { return .red }
        if isProcessing { return .orange }
        return .blue
    }

    private var statusIcon: String {
        if isRecording { return "mic.fill" }
        if isProcessing { return "arrow.triangle.2.circlepath" }
        return "mic"
    }

    private var statusColor: Color {
        if isRecording { return .red }
        if isProcessing { return .orange }
        return .blue
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
                if micGranted && speechGranted {
                    hasPermission = true
                    statusMessage = "就绪，点击开始说话"
                } else {
                    hasPermission = false
                    statusMessage = "请授权麦克风和语音识别权限"
                }
            }
        }
    }

    private func startRecording() {
        isRecording = true
        statusMessage = "正在说话..."
        lastResult = ""

        SpeechService.shared.startRecording { [self] transcript in
            DispatchQueue.main.async {
                self.isRecording = false
                self.lastResult = transcript
                self.optimizeAndInput(transcript)
            }
        }
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
        statusMessage = "AI 优化中..."

        MiniMaxService.shared.optimize(text: transcript, mode: mode) { result in
            DispatchQueue.main.async {
                self.isProcessing = false

                switch result {
                case .success(let optimizedText):
                    self.lastResult = optimizedText
                    self.statusMessage = "已输入"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        KeyboardService.shared.typeText(optimizedText)
                        NotificationService.shared.notifySuccess(text: optimizedText)
                    }
                case .failure(let error):
                    self.statusMessage = "优化失败: \(error.localizedDescription)"
                    NotificationService.shared.notifyFailure(reason: error.localizedDescription)
                    // 降级：直接输入原文本
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        KeyboardService.shared.typeText(transcript)
                    }
                }
            }
        }
    }
}
