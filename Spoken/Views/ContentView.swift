import SwiftUI

enum SpokenMode: String, CaseIterable {
    case text = "文本模式"
    case prompt = "Prompt模式"
}

struct ContentView: View {
    @State private var mode: SpokenMode = .text
    @State private var isRecording = false
    @State private var lastResult = ""
    @State private var statusMessage = "点击开始说话"

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "mic.fill")
                    .foregroundColor(isRecording ? .red : .blue)
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

            // Record Button
            Button(action: toggleRecording) {
                HStack {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    Text(isRecording ? "停止" : "开始说话")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isRecording ? Color.red : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .padding(.horizontal, 16)

            // Status / Result
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

            Spacer()
        }
        .frame(width: 300, height: 200)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        statusMessage = "正在说话..."
        SpeechService.shared.startRecording { transcript in
            DispatchQueue.main.async {
                self.isRecording = false
                self.lastResult = transcript
                self.statusMessage = "处理中..."
                self.processText(transcript)
            }
        }
    }

    private func stopRecording() {
        SpeechService.shared.stopRecording()
        isRecording = false
        statusMessage = "正在识别..."
    }

    private func processText(_ text: String) {
        // TODO: v0.2 MiniMax 优化
        // 目前 v0.1 直接输入原文本
        KeyboardService.shared.typeText(text)
        statusMessage = "已输入"
        lastResult = ""
    }
}
