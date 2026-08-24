import Foundation

/// 只记录计数和耗时，不记录语音或转录内容。
final class ASRStabilityMetrics: @unchecked Sendable {
    static let shared = ASRStabilityMetrics()

    private enum Key {
        static let sessions = "asr_metrics_sessions"
        static let connected = "asr_metrics_connected"
        static let successes = "asr_metrics_successes"
        static let failures = "asr_metrics_failures"
        static let reconnects = "asr_metrics_reconnects"
        static let fallbacks = "asr_metrics_fallbacks"
    }

    private let queue = DispatchQueue(label: "com.moss.spoken.asr-metrics")
    private let defaults = UserDefaults.standard

    private init() {}

    func recordSessionStarted() { increment(Key.sessions) }
    func recordConnected() { increment(Key.connected) }
    func recordCloudSuccess() { increment(Key.successes) }
    func recordCloudFailure() { increment(Key.failures) }
    func recordReconnect() { increment(Key.reconnects) }
    func recordLocalFallback() { increment(Key.fallbacks) }

    func snapshot() -> ASRMetricsSnapshot {
        queue.sync {
            ASRMetricsSnapshot(
                sessions: defaults.integer(forKey: Key.sessions),
                connected: defaults.integer(forKey: Key.connected),
                successes: defaults.integer(forKey: Key.successes),
                failures: defaults.integer(forKey: Key.failures),
                reconnects: defaults.integer(forKey: Key.reconnects),
                fallbacks: defaults.integer(forKey: Key.fallbacks)
            )
        }
    }

    func reset() {
        queue.async {
            [Key.sessions, Key.connected, Key.successes, Key.failures, Key.reconnects, Key.fallbacks]
                .forEach { self.defaults.removeObject(forKey: $0) }
        }
    }

    private func increment(_ key: String) {
        queue.async {
            self.defaults.set(self.defaults.integer(forKey: key) + 1, forKey: key)
        }
    }
}

struct ASRMetricsSnapshot: Equatable {
    let sessions: Int
    let connected: Int
    let successes: Int
    let failures: Int
    let reconnects: Int
    let fallbacks: Int

    var successRate: Double {
        guard successes + failures > 0 else { return 0 }
        return Double(successes) / Double(successes + failures)
    }
}

// MARK: - 端到端耗时

/// 只记录单次处理链路中的时间点与耗时，不记录音频、转录文本或模型输出。
final class PipelineLatencyMetrics: @unchecked Sendable {
    static let shared = PipelineLatencyMetrics()

    enum Event: String, CaseIterable {
        case hotKey
        case panelShown
        case recordingStarted
        case audioEngineStarted
        case firstAudioFrame
        case asrConnected
        case firstASRPartial
        case stopRequested
        case asrCommitSent
        case asrFinal
        case aiRequestStarted
        case aiCompleted
        case injectionStarted
        case injectionCompleted
    }

    struct Distribution: Equatable {
        let count: Int
        let p50: Double
        let p90: Double
        let p95: Double
    }

    private static let logger = UnifiedLogger(
        subsystem: "com.moss.spoken",
        category: "PipelineLatency"
    )
    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let samplesKey = "pipeline_latency_samples_v1"
    private let maxSamplesPerMetric = 50
    private var traceID: UUID?
    private var marks: [Event: TimeInterval] = [:]

    private init() {}

    @discardableResult
    func begin() -> UUID {
        lock.lock()
        let id = UUID()
        traceID = id
        marks = [.hotKey: ProcessInfo.processInfo.systemUptime]
        lock.unlock()
        Self.logger.info("trace=\(shortID(id)) event=hotKey elapsed_ms=0")
        return id
    }

    func mark(_ event: Event) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard let id = traceID, marks[event] == nil else {
            lock.unlock()
            return
        }
        marks[event] = now
        let elapsed = now - (marks[.hotKey] ?? now)
        lock.unlock()
        Self.logger.info("trace=\(shortID(id)) event=\(event.rawValue) elapsed_ms=\(milliseconds(elapsed))")
    }

    func finish() {
        mark(.injectionCompleted)

        lock.lock()
        guard let id = traceID else {
            lock.unlock()
            return
        }
        let currentMarks = marks
        traceID = nil
        marks.removeAll(keepingCapacity: true)
        var stored = defaults.dictionary(forKey: samplesKey) as? [String: [Double]] ?? [:]
        let durations = Self.durations(from: currentMarks)
        for (name, seconds) in durations {
            var values = stored[name] ?? []
            values.append(seconds)
            if values.count > maxSamplesPerMetric {
                values.removeFirst(values.count - maxSamplesPerMetric)
            }
            stored[name] = values
        }
        defaults.set(stored, forKey: samplesKey)
        lock.unlock()

        let summary = durations.keys.sorted().map { name in
            "\(name)=\(milliseconds(durations[name] ?? 0))ms"
        }.joined(separator: " ")
        Self.logger.info("trace=\(shortID(id)) completed \(summary)")
    }

    func abandon() {
        lock.lock()
        traceID = nil
        marks.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func distributions() -> [String: Distribution] {
        lock.lock()
        let stored = defaults.dictionary(forKey: samplesKey) as? [String: [Double]] ?? [:]
        lock.unlock()
        return stored.mapValues(Self.distribution)
    }

    func reset() {
        lock.lock()
        defaults.removeObject(forKey: samplesKey)
        lock.unlock()
    }

    static func distribution(_ values: [Double]) -> Distribution {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return Distribution(count: 0, p50: 0, p90: 0, p95: 0) }
        return Distribution(
            count: sorted.count,
            p50: percentile(0.50, in: sorted),
            p90: percentile(0.90, in: sorted),
            p95: percentile(0.95, in: sorted)
        )
    }

    private static func durations(from marks: [Event: TimeInterval]) -> [String: Double] {
        var result: [String: Double] = [:]
        func add(_ name: String, _ start: Event, _ end: Event) {
            guard let startTime = marks[start], let endTime = marks[end], endTime >= startTime else { return }
            result[name] = endTime - startTime
        }
        add("hotkey_to_panel", .hotKey, .panelShown)
        add("hotkey_to_audio", .hotKey, .audioEngineStarted)
        add("hotkey_to_asr_connected", .hotKey, .asrConnected)
        add("hotkey_to_first_audio", .hotKey, .firstAudioFrame)
        add("hotkey_to_first_text", .hotKey, .firstASRPartial)
        add("stop_to_asr_final", .stopRequested, .asrFinal)
        add("asr_final_to_ai_complete", .asrFinal, .aiCompleted)
        add("ai_request_to_complete", .aiRequestStarted, .aiCompleted)
        add("ai_complete_to_injection", .aiCompleted, .injectionCompleted)
        add("stop_to_injection", .stopRequested, .injectionCompleted)
        add("hotkey_to_injection", .hotKey, .injectionCompleted)
        return result
    }

    private static func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
        let index = Int(ceil(percentile * Double(sorted.count))) - 1
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    private func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
    private func milliseconds(_ seconds: Double) -> Int { Int((seconds * 1_000).rounded()) }
}
