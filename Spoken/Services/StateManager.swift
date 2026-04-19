import Foundation

enum AppState: String, CaseIterable {
    case idle
    case starting
    case recording
    case finishing
    case injecting
    case postProcessing
}

class StateManager: ObservableObject {
    static let shared = StateManager()
    
    @Published var currentState: AppState = .idle
    
    private init() {}
    
    func transition(to newState: AppState) {
        // 防止重复转换到同一状态
        if currentState == newState {
            return
        }
        // 防止在 finishing/injecting/postProcessing 过程中被打断
        if isProcessing() && newState != .idle {
            return
        }
        print("Spoken: [DEBUG] State transition: \(currentState.rawValue) -> \(newState.rawValue)")
        currentState = newState
    }
    
    func isIdle() -> Bool {
        return currentState == .idle
    }
    
    func isRecording() -> Bool {
        return currentState == .recording
    }
    
    func isProcessing() -> Bool {
        return [.starting, .finishing, .injecting, .postProcessing].contains(currentState)
    }
}
