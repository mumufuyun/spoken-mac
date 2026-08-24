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
