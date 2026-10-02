import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdateService
    @ObservedObject private var activity = StateManager.shared
    let navigation: SettingsNavigationGuard

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "arrow.down.circle").font(.system(size: 36)).foregroundStyle(SpokenTheme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Spoken \(updates.versionLabel)").font(.title3.weight(.semibold))
                    if let version = updates.availableVersion {
                        Text("新版本 \(version) 已发布").foregroundStyle(SpokenTheme.accent)
                    } else {
                        Text("更新前可查看本次改进，再决定是否安装。").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(updates.availableVersion == nil ? "检查更新…" : "查看更新…", action: updates.checkForUpdates)
                    .buttonStyle(.borderedProminent)
                    .disabled(!updates.canCheckForUpdates || activity.isBusy() || updates.isInstalling || updates.isWaitingForIdle)
            }
            Divider()
            Toggle("自动检查更新", isOn: Binding(get: { updates.automaticallyChecksForUpdates }, set: updates.setAutomaticChecks))
            Text("启动时及运行期间每 6 小时检查一次。发现新版后提醒，由你确认下载和安装。")
                .font(.callout).foregroundStyle(.secondary)
            if let date = updates.lastCheckDate {
                Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if activity.isBusy() {
                Label("当前录音或文字处理完成后，即可更新。", systemImage: "waveform")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message = updates.statusMessage {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Link("查看下载网页", destination: URL(string: "https://spoken-web-v2.pages.dev/#download")!)
            Spacer()
        }.padding(24)
            .onAppear { navigation.install(isDirty: { false }, save: {}, discard: {}) }
    }
}
