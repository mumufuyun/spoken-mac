import AVFoundation
import XCTest
@testable import Spoken

final class CloudSessionTests: XCTestCase {
    func testReplayBufferKeepsAudioInOrder() {
        var buffer = AudioReplayBuffer(maxBytes: 10)
        buffer.append(Data([1, 2, 3]))
        buffer.append(Data([4, 5]))
        XCTAssertEqual(buffer.buffers, [Data([1, 2, 3]), Data([4, 5])])
        XCTAssertEqual(buffer.byteCount, 5)
    }

    func testReplayBufferDropsOldestAudioAtCapacity() {
        var buffer = AudioReplayBuffer(maxBytes: 5)
        buffer.append(Data([1, 2, 3]))
        buffer.append(Data([4, 5, 6]))
        XCTAssertEqual(buffer.buffers, [Data([4, 5, 6])])
        XCTAssertEqual(buffer.byteCount, 3)
    }

    func testFinalCloudTextWinsOverPartial() {
        XCTAssertEqual(
            CloudRecognitionResultResolver.best(cloudText: "最终文本", latestPartial: "临时文本"),
            "最终文本"
        )
    }

    func testLatestPartialIsUsedWhenFinalTimesOut() {
        XCTAssertEqual(
            CloudRecognitionResultResolver.best(cloudText: nil, latestPartial: "可用的临时结果"),
            "可用的临时结果"
        )
    }

    func testHardwareAudioIsConvertedToCanonicalCloudPCM() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800))
        input.frameLength = 4_800
        for channel in 0..<Int(inputFormat.channelCount) {
            guard let samples = input.floatChannelData?[channel] else { return XCTFail("missing channel") }
            for index in 0..<Int(input.frameLength) {
                samples[index] = sin(Float(index) * 0.01)
            }
        }

        let converter = try XCTUnwrap(StreamingASRPCMConverter(inputFormat: inputFormat))
        let data = try XCTUnwrap(converter.convert(input))
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(data.count % MemoryLayout<Int16>.size, 0)
    }

    func testPostProcessorPreservesNormalChineseTerms() {
        let text = "我们的愿景是开放源码，同时记录地图经纬度和老虎的踪迹。"
        XCTAssertEqual(SpeechPostProcessor.postProcess(text), text)
        XCTAssertEqual(SpeechPostProcessor.postProcess("这个八哥要调用阿皮哎"), "这个bug要调用API")
    }

    func testWarmConnectionIsReusedOnlyWhileFreshAndHealthy() {
        XCTAssertTrue(WarmConnectionReusePolicy.canReuse(
            age: 30,
            maxAge: 180,
            sameAPIKey: true,
            sameModel: true,
            sameEndpoint: true,
            hasTransport: true,
            hasMissedHeartbeat: false
        ))
        XCTAssertFalse(WarmConnectionReusePolicy.canReuse(
            age: 181,
            maxAge: 180,
            sameAPIKey: true,
            sameModel: true,
            sameEndpoint: true,
            hasTransport: true,
            hasMissedHeartbeat: false
        ))
        XCTAssertFalse(WarmConnectionReusePolicy.canReuse(
            age: 30,
            maxAge: 180,
            sameAPIKey: true,
            sameModel: true,
            sameEndpoint: true,
            hasTransport: true,
            hasMissedHeartbeat: true
        ))
        XCTAssertFalse(WarmConnectionReusePolicy.canReuse(
            age: 6 * 60,
            maxAge: 120,
            sameAPIKey: true,
            sameModel: true,
            sameEndpoint: true,
            hasTransport: true,
            hasMissedHeartbeat: false
        ))
        XCTAssertFalse(WarmConnectionReusePolicy.canReuse(
            age: 30,
            maxAge: 180,
            sameAPIKey: true,
            sameModel: true,
            sameEndpoint: false,
            hasTransport: true,
            hasMissedHeartbeat: false
        ))
    }

    func testQwenSessionBecomesReadyOnlyAfterUpdateAcknowledgement() {
        XCTAssertEqual(
            QwenSessionHandshakePolicy.action(for: "session.created"),
            .noteSessionCreated
        )
        XCTAssertEqual(
            QwenSessionHandshakePolicy.action(for: "session.updated"),
            .markReady
        )
        XCTAssertEqual(
            QwenSessionHandshakePolicy.action(for: "conversation.item.input_audio_transcription.text"),
            .ignore
        )
    }

    func testQwenEndpointUsesDedicatedWorkspaceDomainWhenConfigured() throws {
        XCTAssertEqual(
            QwenEndpointResolver.host(workspaceID: nil),
            "dashscope.aliyuncs.com"
        )
        XCTAssertEqual(
            QwenEndpointResolver.host(workspaceID: "  ws-123  "),
            "ws-123.cn-beijing.maas.aliyuncs.com"
        )
        XCTAssertEqual(
            QwenEndpointResolver.host(workspaceID: "invalid.example.com"),
            "dashscope.aliyuncs.com"
        )
        let url = try XCTUnwrap(QwenEndpointResolver.webSocketURL(
            workspaceID: "ws-123",
            model: "qwen3-asr-flash-realtime"
        ))
        XCTAssertEqual(url.host, "ws-123.cn-beijing.maas.aliyuncs.com")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                       "qwen3-asr-flash-realtime")
    }

    func testPCMVoiceActivityDetectorRejectsSilenceAndDetectsSpeech() {
        XCTAssertFalse(PCMVoiceActivityDetector.containsMeaningfulSpeech(Data(repeating: 0, count: 4_096)))

        var samples = [Int16](repeating: 0, count: 2_048)
        for index in 0..<64 { samples[index] = index.isMultiple(of: 2) ? 2_000 : -2_000 }
        let speechData = samples.withUnsafeBytes { Data($0) }
        XCTAssertTrue(PCMVoiceActivityDetector.containsMeaningfulSpeech(speechData))
    }

    func testLatencyDistributionUsesNearestRankPercentiles() {
        let distribution = PipelineLatencyMetrics.distribution([0.1, 0.2, 0.3, 0.4, 0.5])
        XCTAssertEqual(distribution.count, 5)
        XCTAssertEqual(distribution.p50, 0.3, accuracy: 0.0001)
        XCTAssertEqual(distribution.p90, 0.5, accuracy: 0.0001)
        XCTAssertEqual(distribution.p95, 0.5, accuracy: 0.0001)
    }

    func testDeepSeekDashScopeThinkingConfiguration() {
        XCTAssertTrue(MiniMaxService.supportsThinkingToggle(
            model: "deepseek-v4-flash-0731",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        ))
        XCTAssertEqual(MiniMaxService.thinkingRequestValue(
            requested: false,
            model: "deepseek-v4-flash-0731",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        ), false)
        XCTAssertEqual(MiniMaxService.thinkingRequestValue(
            requested: true,
            model: "deepseek-v4-flash-0731",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        ), true)
        XCTAssertNil(MiniMaxService.thinkingRequestValue(
            requested: true,
            model: "MiniMax-M2.5",
            baseURL: "https://api.minimax.chat/v1"
        ))
        XCTAssertEqual(MiniMaxService.maxOutputTokens(forInputLength: 20), 256)
        XCTAssertEqual(MiniMaxService.maxOutputTokens(forInputLength: 2_000), 4_128)
        XCTAssertEqual(MiniMaxService.maxOutputTokens(forInputLength: 20_000), 16_384)
        XCTAssertEqual(MiniMaxService.maxOutputTokens(forInputLength: 20, thinkingEnabled: true), 2_048)
        XCTAssertEqual(MiniMaxService.maxOutputTokens(forInputLength: 2_000, thinkingEnabled: true), 9_024)
        XCTAssertEqual(MiniMaxService.aiTimeout(forInputLength: 500, thinkingEnabled: false), 20)
        XCTAssertEqual(MiniMaxService.aiTimeout(forInputLength: 500, thinkingEnabled: true), 45)
        XCTAssertEqual(MiniMaxService.aiTimeout(forInputLength: 10_000, thinkingEnabled: true), 60)
    }
}
