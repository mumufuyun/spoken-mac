import AppKit

let app = NSApplication.shared
// NSApplication 的入口固定在主线程；显式声明这一事实以满足 actor 隔离检查。
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
