import Foundation

struct AIOutputPolicy {
    var stripWrappers = true
    var isInstruction = false
    var originalText: String?
}

/// Only known final-text fields may enter the output pipeline. Ambiguous output fails closed.
enum AIOutputGuard {
    private static let hiddenTypes: Set<String> = [
        "thinking", "reasoning", "reasoning_content", "reasoning_details", "redacted_thinking", "analysis", "metadata"
    ]
    private static let tagNames = "think|thinking|reasoning|reasoning_content|analysis|reflection|internal_analysis|chain_of_thought|chain-of-thought|metadata"
    private static let tags = regex("(?is)<\\s*(/?)\\s*(" + tagNames + ")\\b[^>]*>")
    private static let tagFragments = regex("(?i)<\\s*/?\\s*(?:" + tagNames + ")(?:\\b|$)")
    private static let protocolMarkers = regex(#"(?i)<\|(?:im_start|im_end|start|end|message|channel|meta_sep|endoftext|eot_id|start_header_id|end_header_id)\|>|\[(?:/?THINK|/?ANALYSIS|/?REASONING)\]"#)
    private static let privateHeading = regex(#"(?im)^\h*(?:#{1,6}\h*)?(?:\*\*|__)?(?:思考过程|思考内容|内部推理|内部分析|推理过程|思维链|chain[ -]of[ -]thought|thinking(?: process)?|reasoning(?: process)?)(?:\*\*|__)?\h*(?:[:：][^\r\n]*|\r?$)"#)
    private static let instructionHeading = regex(#"(?im)^\h*(?:#{1,6}\h*)?(?:\*\*|__)?(?:分析|思考|推理|思路|分析步骤|analysis)(?:\*\*|__)?\h*(?:[:：][^\r\n]*|\r?$)"#)
    private static let narration = regex(#"(?im)^\h*(?:好的[，,。]\h*|首先[，,：:]\h*|(?:\d+[.)、]|[-*])\h*)?(?:我(?:需要|应该|将要|必须|先)(?:先|首先)?(?:分析|理解|判断|确定|梳理|整理)(?:一下)?(?:用户|这段(?:语音|转录)|原始转录)|用户(?:想要|希望|要求|的(?:意图|需求|意思|请求)是)|the user (?:wants|asks|is asking|has asked)|I (?:need to|should|must|will) (?:first )?(?:analy[sz]e|understand|interpret|rewrite|rephrase|organize|respond|figure out))[^\r\n]*"#)

    struct Payload {
        let text: String
        let discardedReasoning: Bool
    }

    static func responseText(_ json: [String: Any]) throws -> Payload {
        if let raw = json["choices"] {
            guard let choices = raw as? [[String: Any]], let first = choices.first else { throw MiniMaxError.parseError }
            if let reason = first["finish_reason"] as? String, !["stop", "end_turn"].contains(reason) {
                throw MiniMaxError.incompleteOutput
            }
            if let rawMessage = first["message"] {
                guard let message = rawMessage as? [String: Any] else { throw MiniMaxError.parseError }
                try validateMessage(message)
                let discarded = hiddenTypes.contains { message[$0] != nil && !(message[$0] is NSNull) }
                guard let content = message["content"], !(content is NSNull) else { throw MiniMaxError.emptyOutput }
                if let text = content as? String {
                    try rejectMirroredReasoning(text, fragments: reasoningFragments(message))
                    return Payload(text: text, discardedReasoning: discarded)
                }
                let blocks = try textBlocks(content)
                try rejectMirroredReasoning(blocks.text, fragments: reasoningFragments(message))
                return Payload(text: blocks.text, discardedReasoning: discarded || blocks.discardedReasoning)
            }
            if let rawMessages = first["messages"] {
                guard let messages = rawMessages as? [[String: Any]], !messages.isEmpty else { throw MiniMaxError.parseError }
                var texts: [String] = []; var discarded = false; var reasoning: [String] = []
                for message in messages {
                    if let type = message["type"] as? String, hiddenTypes.contains(type.lowercased()) {
                        discarded = true
                        reasoning += reasoningFragments(message) + [message["text"] as? String ?? ""]
                        continue
                    }
                    try validateMessage(message)
                    if let type = message["type"] as? String, !["text", "output_text"].contains(type.lowercased()) { throw MiniMaxError.parseError }
                    guard let text = message["text"] as? String else { throw MiniMaxError.parseError }
                    texts.append(text)
                }
                let text = texts.joined()
                try rejectMirroredReasoning(text, fragments: reasoning)
                return Payload(text: text, discardedReasoning: discarded)
            }
            // Do not use a top-level fallback when an explicitly present message is invalid.
            throw MiniMaxError.parseError
        }
        if let output = json["output"] as? String { return Payload(text: output, discardedReasoning: false) }
        throw MiniMaxError.parseError
    }

    private static func validateMessage(_ message: [String: Any]) throws {
        for (field, allowed) in [("role", ["assistant"]), ("sender_type", ["bot", "assistant"]), ("channel", ["final", "answer"])] {
            guard let raw = message[field], !(raw is NSNull) else { continue }
            guard let value = raw as? String else { throw MiniMaxError.parseError }
            if !allowed.contains(value.lowercased()) { throw MiniMaxError.unsafeOutput }
        }
        if let calls = message["tool_calls"], !(calls is NSNull), (calls as? [Any])?.isEmpty != true { throw MiniMaxError.incompleteOutput }
        if let call = message["function_call"], !(call is NSNull) { throw MiniMaxError.incompleteOutput }
    }

    private static func textBlocks(_ raw: Any) throws -> Payload {
        guard let blocks = raw as? [[String: Any]] else { throw MiniMaxError.parseError }
        var text = ""; var discarded = false; var reasoning: [String] = []
        for block in blocks {
            guard let type = (block["type"] as? String)?.lowercased() else { throw MiniMaxError.parseError }
            if hiddenTypes.contains(type) {
                discarded = true
                reasoning += reasoningFragments(block) + [block["text"] as? String ?? ""]
                continue
            }
            guard ["text", "output_text"].contains(type), let value = block["text"] as? String else { throw MiniMaxError.parseError }
            try validateMessage(block)
            text += value
        }
        try rejectMirroredReasoning(text, fragments: reasoning)
        return Payload(text: text, discardedReasoning: discarded)
    }

    private static func reasoningFragments(_ object: [String: Any]) -> [String] {
        var fragments = ["reasoning_content", "reasoning", "thinking"].compactMap { object[$0] as? String }
        fragments += (object["reasoning_details"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return fragments
    }

    private static func rejectMirroredReasoning(_ text: String, fragments: [String]) throws {
        // A provider may separate reasoning yet also copy it into content. Avoid short common
        // phrases; a verbatim substantial reasoning fragment in final text is a strong signal.
        for fragment in fragments {
            let value = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 16 && text.contains(value) { throw MiniMaxError.unsafeOutput }
        }
    }

    static func clean(_ text: String, policy: AIOutputPolicy = AIOutputPolicy()) throws -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Zero-width separators can split otherwise recognizable protocol markers. Normalize only
        // the inspection copy below; preserve the spelling and Unicode of delivered custom content.
        let source = result as NSString
        let protected = codeRanges(result)
        var removals: [NSRange] = []; var stack: [String] = []; var start = 0
        for match in tags.matches(in: result, range: NSRange(location: 0, length: source.length)) {
            // Within a reasoning block, backticks are reasoning too, not an escape hatch.
            if stack.isEmpty && protected.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
            let closing = source.substring(with: match.range(at: 1)) == "/"
            let name = source.substring(with: match.range(at: 2)).lowercased()
            if closing {
                guard stack.last == name else { throw MiniMaxError.unsafeOutput }
                stack.removeLast()
                if stack.isEmpty { removals.append(NSRange(location: start, length: NSMaxRange(match.range) - start)) }
            } else {
                guard !source.substring(with: match.range).hasSuffix("/>") else { throw MiniMaxError.unsafeOutput }
                if stack.isEmpty { start = match.range.location }
                stack.append(name)
            }
        }
        guard stack.isEmpty else { throw MiniMaxError.unsafeOutput }
        let mutable = NSMutableString(string: result)
        for range in removals.reversed() { mutable.replaceCharacters(in: range, with: "") }
        result = String(mutable).trimmingCharacters(in: .whitespacesAndNewlines)
        // Final envelopes are accepted only if they enclose the entire remaining reply.
        if result.range(of: #"(?is)^<(?:final|answer)>"#, options: .regularExpression) != nil {
            let envelope = regex(#"(?is)^<(final|answer)>(.*?)</\1>$"#)
            guard let match = envelope.firstMatch(in: result, range: fullRange(result)) else { throw MiniMaxError.unsafeOutput }
            result = (result as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Old built-ins alone remove presentation prefixes. Never normalize custom Markdown/code.
        if policy.stripWrappers {
            let wrapper = regex(#"(?is)^\s*(?:以下是对语音转录的整理结果(?:，?作为发送给另一个?\s*AI\s*的直接可执行指令)?|以下是整理后的(?:文本|内容|指令)|整理结果如下)\s*[：:]\s*"#)
            result = wrapper.stringByReplacingMatches(in: result, range: fullRange(result), withTemplate: "")
            result = result.precomposedStringWithCompatibilityMapping
        }
        let inspection = proseOnly(result)
            .replacingOccurrences(of: #"[\u200B\u200C\u200D\uFEFF]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        if hasMatch(tagFragments, inspection) || hasMatch(protocolMarkers, inspection)
            || hasMatch(regex(#"(?i)</?(?:final|answer)>"#), inspection)
            || hasMatch(regex(#"(?im)^ {0,3}(?:`{3,}|~{3,})(?:think(?:ing)?|reasoning|analysis|metadata|思考过程|思维链)\h*$"#), inspection) {
            throw MiniMaxError.unsafeOutput
        }
        // Explicit reasoning headers are ambiguous without a reliable protocol boundary.
        // Preserve source-authored headings; never delete a legitimate requested analysis section.
        let original = policy.stripWrappers ? policy.originalText?.precomposedStringWithCompatibilityMapping : policy.originalText
        try rejectNovelMatches(privateHeading, in: inspection, original: original)
        if policy.isInstruction {
            try rejectNovelMatches(instructionHeading, in: inspection, original: original)
            try rejectNovelMatches(narration, in: inspection, original: original)
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] {
            let explicitReasoning = object.keys.contains { ["reasoning_content", "reasoning_details", "chain_of_thought"].contains($0.lowercased()) }
            let mixedEnvelope = ["content", "final", "answer"].contains { object[$0] != nil }
                && object.keys.contains { hiddenTypes.contains($0.lowercased()) }
            let apiEnvelope = object["choices"] != nil && (object["usage"] != nil || object["object"] != nil)
            if explicitReasoning || mixedEnvelope || apiEnvelope { throw MiniMaxError.unsafeOutput }
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MiniMaxError.emptyOutput }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rejectNovelMatches(_ pattern: NSRegularExpression, in text: String, original: String?) throws {
        for match in pattern.matches(in: text, range: fullRange(text)) {
            let phrase = (text as NSString).substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if original?.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) == nil { throw MiniMaxError.unsafeOutput }
        }
    }

    private static func codeRanges(_ text: String) -> [NSRange] {
        let string = text as NSString
        let fence = regex(#"(?m)^ {0,3}(`{3,}|~{3,})([^\r\n]*)"#)
        var ranges: [NSRange] = []; var opening: (start: Int, marker: String)?
        for match in fence.matches(in: text, range: fullRange(text)) {
            let marker = string.substring(with: match.range(at: 1))
            let info = string.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if let current = opening {
                if marker.first == current.marker.first && marker.count >= current.marker.count && info.isEmpty {
                    ranges.append(NSRange(location: current.start, length: NSMaxRange(match.range) - current.start)); opening = nil
                }
            } else {
                // A fence explicitly labelled as reasoning is still reasoning, not generated code.
                if hiddenTypes.contains(info.lowercased()) || ["think", "思考过程", "思维链"].contains(info.lowercased()) { continue }
                opening = (match.range.location, marker)
            }
        }
        if let opening { ranges.append(NSRange(location: opening.start, length: string.length - opening.start)) }
        let inline = regex(#"(`+)[^`\r\n]+\1"#)
        ranges += inline.matches(in: text, range: fullRange(text)).map(\.range).filter { range in
            !ranges.contains { NSIntersectionRange(range, $0).length > 0 }
        }
        return ranges
    }

    private static func proseOnly(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for range in codeRanges(text).reversed() { result.replaceCharacters(in: range, with: String(repeating: " ", count: range.length)) }
        return String(result)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static func fullRange(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }
    private static func hasMatch(_ pattern: NSRegularExpression, _ text: String) -> Bool { pattern.firstMatch(in: text, range: fullRange(text)) != nil }
}
