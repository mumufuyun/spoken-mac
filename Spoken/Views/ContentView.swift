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
    @State private var statusMessage = "语言是最好的输入"

    // ElevenLabs Warm Palette
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
                Text("⌥+空格")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(textMuted)
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(textMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
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
                        Button(action: {
                            translateLang = lang
                            UserDefaults.standard.set(lang.rawValue, forKey: "translateLang")
                            UserDefaults.standard.synchronize()
                        }) {
                            Text(lang.rawValue)
                                .font(.system(size: 11, weight: translateLang == lang ? .medium : .regular))
                                .foregroundColor(translateLang == lang ? .white : textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(translateLang == lang ? accentBlue : Color(hex: "#f5f2ef"))
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

            // 状态文字
            Text(statusMessage)
                .font(.system(size: 12, weight: .regular))
                .tracking(0.16)
                .foregroundColor(textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)

            Spacer().frame(height: 12)
        }
        .frame(width: 260, height: mode == .translate ? 200 : 170)
        .background(
            Color.white
                .shadow(color: Color(hex: "#4e3220").opacity(0.04), radius: 4, x: 0, y: 2)
                .shadow(color: Color(hex: "#000000").opacity(0.02), radius: 1, x: 0, y: 0)
        )
        .onAppear {
            let savedMode = UserDefaults.standard.string(forKey: "spokenMode")
            if let rawValue = savedMode, let saved = SpokenMode(rawValue: rawValue) {
                mode = saved
            }
            let savedLang = UserDefaults.standard.string(forKey: "translateLang")
            if let rawValue = savedLang, let saved = TranslateLanguage(rawValue: rawValue) {
                translateLang = saved
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
        Button(action: {
            current = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "spokenMode")
            UserDefaults.standard.synchronize()
            print("Spoken: [DEBUG] ModeButton: saved mode = \(mode.rawValue)")
        }) {
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
