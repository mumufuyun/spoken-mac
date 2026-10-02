import Foundation

/// 仅合并识别结果中缩写字母之间的空格，不进行固定词语替换。
/// 术语消歧交由需要 AI 整理的场景结合上下文处理。
enum SpeechPostProcessor {
    static func postProcess(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return collapseSpacedAcronyms(in: text)
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
