import AppKit
import Combine

protocol RecoveryTextProcessing: AnyObject {
    func process(text: String, snapshot: AIProcessingSnapshot, completion: @escaping (Result<String, Error>) -> Void)
    func cancelCurrentTask()
}

extension AIProcessingService: RecoveryTextProcessing {}

/// Retains one ASR original in memory; the presentation owner delivers validated results.
@MainActor
final class InputRecoveryStore: ObservableObject {
    static let shared = InputRecoveryStore(modes: .shared, activity: .shared)

    struct Entry {
        let id = UUID()
        let original: String
        let mayBeIncomplete: Bool
    }

    enum Display: String, CaseIterable { case original = "原文", result = "整理结果" }

    @Published private(set) var entry: Entry?
    @Published private(set) var result: String?
    @Published private(set) var resultMode: ModeDefinition?
    @Published private(set) var selectedModeID: String?
    @Published private(set) var processingModeName: String?
    @Published private(set) var isProcessing = false
    @Published private(set) var inputIsBusy = false
    @Published private(set) var notice: String?
    @Published private(set) var copyNotice: String?
    @Published var display: Display = .original
    var onProcessed: ((String) -> Void)?

    let modes: ModeStore
    private let processor: RecoveryTextProcessing
    private let snapshotProvider: (String) throws -> AIProcessingSnapshot
    private let copyText: (String) -> Bool
    private let canStart: () -> Bool
    private let activity: StateManager?
    private var requestID: UUID?
    private var activitySubscription: AnyCancellable?

    init(modes: ModeStore, processor: RecoveryTextProcessing = AIProcessingService(recordsMetrics: false),
         activity: StateManager? = nil,
         snapshotProvider: ((String) throws -> AIProcessingSnapshot)? = nil,
         canStart: (() -> Bool)? = nil,
         copyText: @escaping (String) -> Bool = { text in
             NSPasteboard.general.clearContents()
             return NSPasteboard.general.setString(text, forType: .string)
         }) {
        self.modes = modes
        self.processor = processor
        self.activity = activity
        self.snapshotProvider = snapshotProvider ?? { id in
            try AIProcessingSnapshot.capture(modes: modes, connections: .shared, modeID: id)
        }
        self.canStart = canStart ?? { !AppUpdateService.shared.isInstalling }
        self.copyText = copyText
        activitySubscription = activity?.$currentState.sink { [weak self] state in
            self?.inputStateChanged(state)
        }
    }

    var canReprocess: Bool { entry != nil && !inputIsBusy && !isProcessing && canStart() }
    var selectedMode: ModeDefinition? { modes.modes.first { $0.id == selectedModeID } }
    var displayedText: String { display == .result ? (result ?? entry?.original ?? "") : (entry?.original ?? "") }
    var copyLabel: String { display == .result && result != nil ? "复制结果" : "复制原文" }

    func capture(_ original: String, mayBeIncomplete: Bool = false) {
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelProcessing()
        entry = Entry(original: original, mayBeIncomplete: mayBeIncomplete)
        result = nil
        resultMode = nil
        selectedModeID = nil
        display = .original
        notice = nil
        copyNotice = nil
    }

    /// Choose the current application scene once per retained original, without writing ModeStore.
    func prepareForPresentation() {
        if selectedModeID == nil { selectedModeID = modes.selected.id }
        copyNotice = nil
    }

    func selectMode(_ id: String) {
        guard !isProcessing, !inputIsBusy, modes.modes.contains(where: { $0.id == id }) else { return }
        selectedModeID = id
        notice = nil
        copyNotice = nil
    }

    func inputStateChanged(_ state: AppState) {
        inputIsBusy = state != .idle && state != .recovering
        // @Published delivers before StateManager changes its value. Never write .idle here:
        // a new recording owns the incoming state and must cancel us synchronously.
        if inputIsBusy { cancelProcessing(releaseActivity: false) }
    }

    func reprocess() {
        guard canReprocess, let entry else { return }
        prepareForPresentation()
        notice = nil
        let snapshot: AIProcessingSnapshot
        do { snapshot = try snapshotProvider(selectedModeID!) }
        catch {
            notice = "无法重新整理：\(error.localizedDescription)。仍可复制原文。"
            return
        }
        // Only discard the previous result once a valid new request can start.
        result = nil
        resultMode = nil
        display = .original
        let id = UUID()
        // Freeze the delivery destination with this request, just like its scene settings.
        let deliverResult = onProcessed
        requestID = id
        processingModeName = snapshot.mode.name
        isProcessing = true
        activity?.transition(to: .recovering)
        let text = SpeechPostProcessor.postProcess(entry.original.trimmingCharacters(in: .whitespacesAndNewlines))
        processor.process(text: text, snapshot: snapshot) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self, self.requestID == id, self.entry?.id == entry.id else { return }
                self.requestID = nil
                self.isProcessing = false
                self.processingModeName = nil
                let validated = outcome.flatMap {
                    AIProcessingService.validatedOutput($0, stripWrappers: !snapshot.mode.isCustom,
                        isInstruction: snapshot.mode.builtin == .aiInstruction, originalText: text)
                }
                switch validated {
                case .success(let text):
                    self.result = text
                    self.resultMode = snapshot.mode
                    self.display = .result
                    deliverResult?(text)
                case .failure: self.notice = "重新整理失败，仍可复制原文。"
                }
                self.releaseActivity()
            }
        }
    }

    func cancelProcessing() { cancelProcessing(releaseActivity: true) }

    private func cancelProcessing(releaseActivity: Bool) {
        guard requestID != nil else { return }
        requestID = nil
        isProcessing = false
        processingModeName = nil
        processor.cancelCurrentTask()
        notice = "已取消整理，仍可复制原文。"
        if releaseActivity { self.releaseActivity() }
    }

    private func releaseActivity() {
        if activity?.currentState == .recovering { activity?.transition(to: .idle) }
    }

    func copyDisplayedText() {
        guard entry != nil else { return }
        copyNotice = copyText(displayedText) ? (copyLabel == "复制结果" ? "已复制结果" : "已复制原文") : "复制失败，请选中文字后重试。"
    }
}
