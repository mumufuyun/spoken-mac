import SwiftUI

struct AccessibilityMenuNotice: View {
    @ObservedObject var service: AccessibilityPermissionService
    var onGuide: () -> Void
    var body: some View {
        if service.needsAttention {
            VStack(alignment: .leading, spacing: 8) {
                Label(service.state.statusText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                Text("文字可以生成，但无法自动填入输入框。完成后请按 ⌘V 手动粘贴。")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Button("完成辅助功能授权", action: onGuide).controlSize(.small)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(SpokenTheme.inset, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Shared by the first-launch guide and the permanent settings page.
struct AccessibilityGuideView: View {
    @ObservedObject var service: AccessibilityPermissionService
    var onLater: (() -> Void)?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(service.state.statusText, systemImage: service.canAutoPaste ? "checkmark.circle.fill" : "hand.raised.fill")
                        .font(.headline).foregroundStyle(service.canAutoPaste ? Color.green : Color.orange)
                        .accessibilityLabel("自动输入权限：" + service.state.statusText)
                    Text("让说完的话，直接进入输入框")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Spoken 通过辅助功能发送粘贴操作，将结果填入你正在使用的输入框。麦克风授权只允许录音，不能代替这项权限。")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    if service.needsAttention {
                        Text("可以稍后授权；在此之前，结果会保留在剪贴板，需要你按 ⌘V 手动粘贴。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. 打开系统设置 → 隐私与安全性 → 辅助功能。")
                    Text("2. 找到 Spoken 并打开开关；系统可能要求验证身份。")
                    Text("3. 回到 Spoken，确认显示“辅助功能已授权”；也可点击“重新检测”。")
                }.font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("打开辅助功能设置") { service.openSettings() }.buttonStyle(.borderedProminent)
                    Button("重新检测") { service.recheck() }
                }
                if let feedback = service.feedback {
                    Text(feedback).font(.callout).foregroundStyle(service.canAutoPaste ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("列表没有 Spoken，或已开启仍不生效？") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("列表没有 Spoken：点击系统设置列表下方的“+”，选择当前运行的 Spoken.app，再打开开关。")
                        Button("在 Finder 中显示当前应用") { service.revealApplication() }
                        Text("更新或替换应用后，旧授权可能失效。先重新检测；仍未生效时，在辅助功能列表中移除旧的 Spoken，再用“+”添加当前应用。如果系统要求，退出并重新打开 Spoken。")
                        Text("已授权但某个输入框仍无法填入时，请确认光标位于可编辑区域。授权状态不代表每个应用都已成功接收文字。")
                    }.font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onLater {
                    HStack {
                        Spacer()
                        Button(service.canAutoPaste ? "完成" : "稍后设置", action: onLater)
                    }
                }
            }.padding(24)
        }
        .background(SpokenTheme.background).tint(SpokenTheme.accent)
        .onAppear { service.guideAppeared() }
        .onDisappear { service.guideDisappeared() }
    }
}

struct AccessibilitySettingsView: View {
    let service: AccessibilityPermissionService
    let navigation: SettingsNavigationGuard
    var body: some View {
        AccessibilityGuideView(service: service)
            .onAppear { navigation.install(isDirty: { false }, save: {}, discard: {}) }
    }
}

/// Delivery feedback stays outside the result and does not activate the target app.
struct TextDeliveryNotice: View {
    let message: String
    var onAuthorize: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Label(message, systemImage: "info.circle").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .help("关闭提示").accessibilityLabel("关闭提示")
            }
            HStack {
                if let onAuthorize { Button("完成辅助功能授权", action: onAuthorize) }
                if let onCopy { Button("重试复制", action: onCopy) }
            }.controlSize(.small)
        }.padding(16).frame(width: 420, alignment: .leading)
            .background(SpokenTheme.background, in: RoundedRectangle(cornerRadius: 12))
            .tint(SpokenTheme.accent)
    }
}
