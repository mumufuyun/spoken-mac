import Foundation

/// 只修正高置信度的语音音译错误。
/// 正常中文词、品牌名和行业名称不在这里无上下文替换，
/// 避免“源码”、“愿景”、“经纬”等正常内容被改变原意。
enum SpeechPostProcessor {
    private static let highConfidenceMappings: [(wrong: String, right: String)] = [
        ("阿皮哎", "API"),
        ("爱劈唉", "API"),
        ("诶批艾", "API"),
        ("艾斯迪凯", "SDK"),
        ("埃斯迪凯", "SDK"),
        ("八哥", "bug"),
        ("巴格", "bug"),
        ("欧克", "OK"),
        ("欧凯", "OK"),
    ]

    static func postProcess(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (wrong, right) in highConfidenceMappings.sorted(by: { $0.wrong.count > $1.wrong.count }) {
            result = result.replacingOccurrences(of: wrong, with: right)
        }
        return collapseSpacedAcronyms(in: result)
    }

    private static func collapseSpacedAcronyms(in text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9])([A-Za-z0-9])(?:\s+([A-Za-z0-9])){2,}(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let collapsed = result[range].filter { !$0.isWhitespace }
            result.replaceSubrange(range, with: collapsed)
        }
        return result
    }
}
