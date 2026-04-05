import Foundation

/// MiniMax API 服务
/// API Key 格式：sk-cp-xxx (新版) 或旧版格式
class MiniMaxService {
    static let shared = MiniMaxService()

    // 凭证
    // TODO: 上线前改成安全的存储方式（Keychain 或配置文件）
    private let apiKey = "sk-cp-Feg_2DXayfN4ChLCbLTk3LvnnJRslowaGwb4grRbyTHNnjS4fJ-SvNRLRw2G62imJUoKVJG55blkhjnQ7V6o9Q1f-el5TfR5WDQj9q6l_LhyEsY16h0vB_E"
    private let baseURL = "https://api.minimax.chat/v1"

    private init() {}

    // MARK: - 文本优化

    /// 语音转文字后，润色优化
    /// - Parameters:
    ///   - text: 原始语音识别文本
    ///   - mode: 当前模式（文本 / Prompt）
    ///   - completion: 回调（优化后文本 或 错误）
    func optimize(
        text: String,
        mode: SpokenMode,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let prompt: String
        let model = "abab6.5s"  // 稳定模型

        switch mode {
        case .text:
            prompt = """
            你是一个文字优化助手。用户输入了一段语音转文字的内容，可能有错字、口水话、语气不通顺。

            请帮他润色成通顺、简洁、得体的中文文本，保持原意。如果有明显错误请纠正，但不要过度修改。

            只输出优化后的文本，不要解释，不要加引号，不要加前缀。

            用户输入：
            \(text)
            """
        case .prompt:
            prompt = """
            你是一个 Prompt 工程助手。用户的输入是他想对 AI 说的话，请把它重构为一个结构清晰、意图明确、包含必要上下文的 AI Prompt。

            要求：
            1. 明确任务目标
            2. 提供必要的输入信息
            3. 说明输出格式（如需要）

            只输出优化后的 Prompt，不要解释，不要加引号，不要加前缀。

            用户输入：
            \(text)
            """
        }

        chat(model: model, prompt: prompt, completion: completion)
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

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": temperature
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(MiniMaxError.noData))
                return
            }

            // 打印原始响应，方便调试
            if let respStr = String(data: data, encoding: .utf8) {
                print("MiniMax raw response: \(respStr)")
            }

            // 解析响应
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let code = json?["status_code"] as? Int, code != 0 {
                    let msg = json?["status_msg"] as? String ?? "Unknown error"
                    completion(.failure(MiniMaxError.apiError(code: code, message: msg)))
                    return
                }

                // 提取 assistant 的回复
                if let choices = json?["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["messages"] as? [[String: Any]],
                   let content = message.first?["text"] as? String {
                    completion(.success(content))
                } else if let choices = json?["choices"] as? [[String: Any]],
                          let first = choices.first,
                          let message = first["message"] as? [String: Any],
                          let content = message["content"] as? String {
                    completion(.success(content))
                } else {
                    // 尝试其他响应格式
                    if let output = json?["output"] as? String {
                        completion(.success(output))
                    } else {
                        completion(.failure(MiniMaxError.parseError))
                    }
                }
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
        case .invalidURL:
            return "无效的 API URL"
        case .noData:
            return "服务器未返回数据"
        case .parseError:
            return "响应解析失败"
        case .apiError(let code, let message):
            return "API 错误 (\(code)): \(message)"
        }
    }
}
