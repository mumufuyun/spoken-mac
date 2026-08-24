import XCTest
@testable import Spoken

final class WritingSceneTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "WritingSceneTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAllPrimaryScenesAreAvailable() {
        XCTAssertEqual(
            Set(WritingScene.allCases),
            Set([.rawTranscript, .casualChat, .workMessage, .formalDocument, .meetingNotes, .contentShare, .aiInstruction])
        )
    }

    func testLegacyPolishMigratesToCasualChatAndOriginalLanguage() {
        defaults.set("润色", forKey: "spokenMode")
        defaults.set("英文", forKey: "translateLang")

        XCTAssertEqual(WritingScene.load(from: defaults), .casualChat)
        XCTAssertEqual(defaults.string(forKey: "translateLang"), TranslateLanguage.original.rawValue)
    }

    func testLegacyTranslateKeepsTargetLanguage() {
        defaults.set("翻译", forKey: "spokenMode")
        defaults.set("日文", forKey: "translateLang")

        XCTAssertEqual(WritingScene.load(from: defaults), .rawTranscript)
        XCTAssertEqual(defaults.string(forKey: "translateLang"), "日文")
    }

    func testSavedSceneWinsOverLegacyMode() {
        defaults.set(WritingScene.formalDocument.rawValue, forKey: WritingScene.defaultsKey)
        defaults.set("直接输入", forKey: "spokenMode")
        XCTAssertEqual(WritingScene.load(from: defaults), .formalDocument)
        XCTAssertEqual(defaults.string(forKey: WritingScene.defaultsKey), WritingScene.formalDocument.storageID)
    }

    func testSceneSavesUsingStableIdentifier() {
        WritingScene.contentShare.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: WritingScene.defaultsKey), "content_share")
        XCTAssertEqual(WritingScene.load(from: defaults), .contentShare)
    }

    func testRemoteLLMRequiresHTTPSButLocalHTTPIsAllowed() {
        XCTAssertNil(MiniMaxService.chatEndpoint(for: "http://api.example.com/v1"))
        XCTAssertEqual(
            MiniMaxService.chatEndpoint(for: "http://127.0.0.1:11434/v1/")?.absoluteString,
            "http://127.0.0.1:11434/v1/chat/completions"
        )
        XCTAssertEqual(
            MiniMaxService.chatEndpoint(for: "https://api.example.com/v1")?.absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
    }

    func testSceneSuggestionUsesMessagingAndDocumentApps() {
        XCTAssertEqual(
            SceneSuggestionEngine.suggest(bundleIdentifier: "com.tencent.xinWeChat", localizedName: "微信"),
            .casualChat
        )
        XCTAssertEqual(
            SceneSuggestionEngine.suggest(bundleIdentifier: "com.apple.iWork.Pages", localizedName: "Pages"),
            .formalDocument
        )
        XCTAssertEqual(
            SceneSuggestionEngine.suggest(bundleIdentifier: "com.openai.chat", localizedName: "ChatGPT"),
            .aiInstruction
        )
    }

    func testEveryAISceneHasAConstrainedDefaultPrompt() {
        for scene in WritingScene.allCases where scene.requiresAI {
            let prompt = MiniMaxService.defaultPrompt(for: scene)
            XCTAssertTrue(prompt.contains("不得虚构"), "\(scene.rawValue) 缺少防虚构约束")
            XCTAssertTrue(prompt.contains("确定程度"), "\(scene.rawValue) 缺少事实边界约束")
            XCTAssertTrue(prompt.contains("{text}"), "\(scene.rawValue) 缺少输入占位符")
        }
    }

    func testHighRiskSceneConstraintsArePresent() {
        let workPrompt = MiniMaxService.defaultPrompt(for: .workMessage)
        XCTAssertTrue(workPrompt.contains("只有原文包含明确诉求"))
        XCTAssertTrue(workPrompt.contains("保持原有逻辑顺序"))

        let meetingPrompt = MiniMaxService.defaultPrompt(for: .meetingNotes)
        XCTAssertTrue(meetingPrompt.contains("建议、设想、倾向和提议"))
        XCTAssertTrue(meetingPrompt.contains("才列为待办"))
        XCTAssertTrue(meetingPrompt.contains("不得用“待办（建议/未明确负责人）”"))
        XCTAssertTrue(meetingPrompt.contains("不得建议由谁跟进"))

        let contentPrompt = MiniMaxService.defaultPrompt(for: .contentShare)
        XCTAssertTrue(contentPrompt.contains("自行添加总结、评价、号召、展望或后续承诺"))
        XCTAssertTrue(contentPrompt.contains("原文明确要求总结或收尾"))
        XCTAssertTrue(contentPrompt.contains("不得推断或补写缺失的分析、判断和结论"))

        let formalPrompt = MiniMaxService.defaultPrompt(for: .formalDocument)
        XCTAssertTrue(formalPrompt.contains("不得为了材料完整而补充解释、意义、影响或推导结论"))
    }

    func testAIInstructionPromptOrganizesWithoutExecuting() {
        let prompt = MiniMaxService.defaultPrompt(for: .aiInstruction)
        XCTAssertTrue(prompt.contains("只整理指令"))
        XCTAssertTrue(prompt.contains("不要回答问题、执行任务"))
        XCTAssertTrue(prompt.contains("目标、背景、要求、输出"))
        XCTAssertTrue(prompt.contains("不保留对 Spoken 的称呼"))
        XCTAssertTrue(prompt.contains("建议仍是建议"))
    }

    func testAIResponseWrapperIsRemoved() {
        let wrapped = "以下是对语音转录的整理结果，作为发送给另一AI的直接可执行指令：\n帮我检查这个方案的逻辑。"
        XCTAssertEqual(MiniMaxService.cleanResponse(wrapped), "帮我检查这个方案的逻辑。")
        XCTAssertEqual(MiniMaxService.cleanResponse("以下是整理后的指令：整理会议材料"), "整理会议材料")
        XCTAssertEqual(MiniMaxService.cleanResponse("下个⽉做⼀次测试"), "下个月做一次测试")
    }

    func testPersonalContextIsBoundedAsReferenceInformation() {
        let prompt = MiniMaxService.applyingPersonalContext(
            "称呼：测试用户。不得自动写入。\n工作领域：AI for Science",
            to: "整理以下文字：测试内容"
        )
        XCTAssertFalse(prompt.contains("称呼：测试用户"))
        XCTAssertTrue(prompt.contains("工作领域：AI for Science"))
        XCTAssertTrue(prompt.contains("不得据此补充原文没有表达的事实"))
        XCTAssertTrue(prompt.contains("不得把背景中的姓名或称呼自动写入输出"))
        XCTAssertTrue(prompt.contains("不得额外追加原文没有的英文别名"))
        XCTAssertTrue(prompt.contains("整理以下文字：测试内容"))
    }

    /// 手动真实模型评测入口。默认跳过，避免常规测试产生网络请求和费用。
    /// 运行时设置 SPOKEN_LIVE_EVAL_OUTPUT=/tmp/spoken_prompt_eval.json。
    func testLiveScenarioEvaluation() throws {
        let configuredOutputPath = ProcessInfo.processInfo.environment["SPOKEN_LIVE_EVAL_OUTPUT"]
            ?? UserDefaults.standard.string(forKey: "liveEvalOutputPath")
        guard let outputPath = configuredOutputPath,
              !outputPath.isEmpty else {
            throw XCTSkip("仅在显式指定真实评测输出路径时运行")
        }
        XCTAssertNotNil(SecureKeyStorage.shared.readAPIKey(), "缺少已配置的 LLM API Key")

        let samples: [(id: String, title: String, expected: String, text: String)] = [
            (
                "S1", "短文本·家庭沟通", "日常聊天",
                "嗯那个我今天晚上可能会晚一点回去，大概九点多吧，你们不用等我吃饭了，我到时候自己弄点就行。"
            ),
            (
                "S2", "中短文本·工作协商", "工作沟通",
                "我看了一下这周BioMaster的用户反馈，大家对单细胞分析这块兴趣挺高的，但是新手第一次用还是不太知道从哪开始。我的想法是咱们先别急着加很多功能，能不能先把首次使用的引导和示例任务补完整，然后找几个老师再试一轮，看看问题到底是在产品能力还是使用门槛。"
            ),
            (
                "S3", "长文本·方案思路", "正式材料",
                "关于玻尔科学空间接下来在高校里面怎么做用户增长，我现在有一个还比较初步的想法。就是我们不能一上来只讲这是一个很强的AI for Science产品，因为不同学科老师对这个概念的理解差别挺大的。材料和化学的老师可能更关注计算、数据和科研软件能不能直接跑起来，生物和医药的用户可能更关心数据分析、文献证据还有结果是不是可信。所以前期方案我觉得可以先按学科拆几类典型任务，再去找一批真实科研人员访谈和试用。这里面哪些渠道最有效、最后要设什么转化指标，我现在还没有结论，需要先做调研。Spoken先帮我把这段思路严谨地整理一下，不要扩写成完整方案。"
            ),
            (
                "S4", "长文本·会议信息", "会议记录",
                "今天会上我们主要讨论了下个月科研Agent体验活动的安排。大家基本同意第一场先聚焦材料和化学方向，不要同时铺太多学科。内容上先用一个真实问题演示SciMaster怎么做文献调研，再让MatMaster接着做分析。小李负责在本周五之前整理候选案例，我下周二跟两位高校老师确认他们是否愿意参加。活动时间暂时放在下个月中旬，但具体日期还没有定。另外还有一个分歧，市场同学希望活动规模做大一点，产品团队更希望先控制在20人左右验证流程，这个问题今天没有结论，下次会继续讨论。"
            ),
            (
                "S5", "中长文本·内容与AI指令", "内容分享 / AI指令",
                "我想让AI帮我把下面这段周末经历整理成一条朋友圈，但不要写得像小红书营销文。周六我跟家里人去郊外徒步，本来以为路线挺轻松，结果后半段一直爬坡，大家都有点累。不过走到山顶的时候天气突然放晴，能看到很远的城市，那个瞬间还是挺值得的。想表达的不是挑战自己或者战胜困难，就是平时工作一直在看AI和互联网，偶尔出去走一走，人会安静一点。文字自然一点，控制在两三段，不要加标题，也不要编具体地点。"
            ),
            (
                "S6", "高风险·不确定性边界", "工作沟通 / 正式材料",
                "关于下个月的用户活动，我目前只是倾向先做材料方向，人数可能控制在20到30人，时间预计在15号前后，但这些都还没有定。我建议这周先问完3位老师，再决定要不要同时加化学方向。注意，这不是已经确认的方案。"
            ),
            (
                "S7", "高风险·非会议设想", "会议记录边界",
                "我刚才自己想了一下，不是开会，也没有定下来。新用户引导也许可以拆成三个步骤，先选科研领域，再跑一个示例任务，最后告诉他去哪看结果。这个只是我的初步设想，目前没有负责人，也没有排期，更不是已经确定的待办。"
            ),
            (
                "S8", "高风险·产品名误识别", "工作沟通 / 术语纠错",
                "我们接下来想在波儿科学空间里面做一个拜欧大师的新手案例，再看看塞大师做文献调研和卖特大师做材料分析能不能串起来。这个名字可能识别得不太准，你帮我按我们常用的产品名纠正一下。"
            ),
            (
                "S9", "高风险·明确要求收尾", "内容分享",
                "这周我们访谈了3位老师，大家对BioMaster有兴趣，但第一次使用不知道怎么开始。我想写成一段工作分享，前面讲现象，中间讲判断，最后请明确加一句总结：先把首次使用路径跑通，再考虑扩大推广。不要写成营销文，也不要添加这个结论之外的展望。"
            ),
        ]
        let modes: [WritingScene] = [
            .casualChat, .workMessage, .formalDocument,
            .meetingNotes, .contentShare, .aiInstruction,
        ]
        var records: [[String: Any]] = []

        for sample in samples {
            for mode in modes {
                let expectation = expectation(description: "\(sample.id)-\(mode.storageID)")
                expectation.assertForOverFulfill = true
                let start = Date()
                var output = ""
                var succeeded = false
                MiniMaxService.shared.process(
                    text: sample.text,
                    mode: mode,
                    translateLang: .original
                ) { result in
                    switch result {
                    case .success(let text):
                        output = text
                        succeeded = true
                    case .failure(let error):
                        output = error.localizedDescription
                    }
                    expectation.fulfill()
                }
                wait(for: [expectation], timeout: 30)
                records.append([
                    "sample_id": sample.id,
                    "sample_title": sample.title,
                    "expected_scene": sample.expected,
                    "input": sample.text,
                    "mode": mode.rawValue,
                    "mode_id": mode.storageID,
                    "success": succeeded,
                    "duration_seconds": Date().timeIntervalSince(start),
                    "output": output,
                ])
            }
        }

        let defaults = UserDefaults.standard
        let payload: [String: Any] = [
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "provider": defaults.string(forKey: "llm_provider") ?? "",
            "model": defaults.string(forKey: "llm_custom_model") ?? "",
            "personal_context_enabled": defaults.object(forKey: PersonalContextStore.enabledKey) == nil
                || defaults.bool(forKey: PersonalContextStore.enabledKey),
            "records": records,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertEqual(records.count, samples.count * modes.count)
    }
}
