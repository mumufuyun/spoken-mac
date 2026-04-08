import Foundation

/// MiniMax API 服务
class MiniMaxService {
    static let shared = MiniMaxService()

    private let apiKey = "sk-cp-Feg_2DXayfN4ChLCbLTk3LvnnJRslowaGwb4grRbyTHNnjS4fJ-SvNRLRw2G62imJUoKVJG55blkhjnQ7V6o9Q1f-el5TfR5WDQj9q6l_LhyEsY16h0vB_E"
    private let baseURL = "https://api.minimax.chat/v1"

    private init() {}

    // MARK: - 统一处理入口

    func process(
        text: String,
        mode: SpokenMode,
        translateLang: TranslateLanguage,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        switch mode {
        case .direct:
            completion(.success(text))
        case .polish:
            polish(text: text, completion: completion)
        case .prompt:
            toPrompt(text: text, completion: completion)
        case .translate:
            translate(text: text, to: translateLang, completion: completion)
        case .summarize:
            summarize(text: text, completion: completion)
        case .format:
            format(text: text, completion: completion)
        }
    }

    // MARK: - 润色

    private func polish(text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let prompt = """
        你是一个文字优化助手。用户输入了一段语音转文字的内容，可能有：
        1. 错别字
        2. 标点符号缺失或断句混乱
        3. 重复表达
        4. 口语化表达

        请优化处理，只输出优化后的文本，不要解释，不要加引号，不要加前缀。

        用户输入：\(text)
        """
        chat(model: "abab6.5s", prompt: prompt, completion: completion)
    }

    // MARK: - Prompt 生成

    private func toPrompt(text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let prompt = """
        你是一个 Prompt 工程助手。用户的输入是他想对 AI 说的话，请把它重构为一个结构清晰、意图明确、包含必要上下文的 AI Prompt。

        要求：
        1. 明确任务目标
        2. 提供必要的输入信息
        3. 说明输出格式（如需要）

        只输出优化后的 Prompt，不要解释，不要加引号，不要加前缀。

        用户输入：\(text)
        """
        chat(model: "abab6.5s", prompt: prompt, completion: completion)
    }

    // MARK: - 翻译

    private func translate(
        text: String,
        to: TranslateLanguage,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let langName: String
        switch to {
        case .english: langName = "英文"
        case .japanese: langName = "日文"
        case .korean: langName = "韩文"
        }

        let prompt = """
        将下面的文字翻译成\(langName)，只输出翻译结果，不要解释，不要加引号，不要加前缀。

        用户输入：\(text)
        """
        chat(model: "abab6.5s", prompt: prompt, completion: completion)
    }

    // MARK: - 摘要

    private func summarize(text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let prompt = """
        你是一个信息摘要助手。用户的输入是一段语音转文字的内容，可能比较冗长、口语化。

        请提取关键信息，生成一段简洁的摘要。保留核心要点，去除重复和口语化的废话。

        只输出摘要结果，不要解释，不要加引号，不要加前缀。

        用户输入：\(text)
        """
        chat(model: "abab6.5s", prompt: prompt, completion: completion)
    }

    // MARK: - 格式化

    private func format(text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let prompt = """
        你是一个内容结构化助手。用户的输入是语音转文字的散乱内容。

        请将内容整理成清晰有结构的格式（bullet points、编号列表等），适合快速阅读和编辑。

        只输出格式化后的内容，不要解释，不要加引号，不要加前缀。

        用户输入：\(text)
        """
        chat(model: "abab6.5s", prompt: prompt, completion: completion)
    }

    // MARK: - 核心请求

    private func chat(
        model: String,
        prompt: String,
        temperature: Double = 0.3,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/text/chatcompletion_v2") else {
            completion(.failure(MiniMaxError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": temperature
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        let task = URLSession.shared.dataTask(with: request) { rawData, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = rawData else {
                completion(.failure(MiniMaxError.noData))
                return
            }

            if let debugStr = String(data: data, encoding: .utf8) {
                print("MiniMax raw: \(debugStr.prefix(300))")
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(MiniMaxError.parseError))
                    return
                }

                if let code = json["status_code"] as? Int, code != 0 {
                    let msg = json["status_msg"] as? String ?? "Unknown error"
                    completion(.failure(MiniMaxError.apiError(code: code, message: msg)))
                    return
                }

                // 格式1: choices[0].messages[0].text
                if let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let messages = first["messages"] as? [[String: Any]],
                   let text = messages.first?["text"] as? String {
                    completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }

                // 格式2: choices[0].message.content
                if let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let text = message["content"] as? String {
                    completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }

                // 格式3: output
                if let output = json["output"] as? String {
                    completion(.success(output.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }

                completion(.failure(MiniMaxError.parseError))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }
}

// MARK: - 错误定义

enum MiniMaxError: LocalizedError {
    case invalidURL
    case noData
    case parseError
    case apiError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 API URL"
        case .noData: return "服务器未返回数据"
        case .parseError: return "响应解析失败"
        case .apiError(let code, let message): return "API 错误 (\(code)): \(message)"
        }
    }
}
