import SwiftUI
import UIKit

struct ConnectionView: View {
    @Bindable var model: PhoneLocationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("本机配对") {
                    Label(model.hasPairing ? "配对记录已就绪" : "尚未配对", systemImage: model.hasPairing ? "checkmark.shield" : "iphone")
                    Text(model.pairingMessage).font(.subheadline).foregroundStyle(.secondary)
                    if let code = model.pairingCode {
                        Text(code).font(.largeTitle.monospaced().bold()).frame(maxWidth: .infinity)
                            .privacySensitive()
                        Text("此码仅用于本次配对，请勿分享。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.pairing {
                        ProgressView("等待系统配对完成…")
                        Text("在系统设置输入手机解锁密码后，再输入本页或通知显示的配对码；完成后回到本 App。")
                            .font(.caption)
                        Button("取消本次配对", role: .cancel) { Task { await model.cancelPairing() } }
                    } else {
                        Button(model.hasPairing ? "重新配对这台 iPhone" : "配对这台 iPhone") {
                            Task { await model.startPairing() }
                        }
                        .disabled(model.busy || model.needsRecovery)
                        .accessibilityIdentifier("pairThisPhone")
                    }
                    if model.needsRecovery {
                        Text("请先停止模拟，在 Apple 地图确认恢复后点“已确认恢复”，再重新配对。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("设备隧道") {
                    Text("打开 LocalDevVPN 并连接，保持 Wi‑Fi 和系统开发者模式开启，然后返回这里检查定位服务。")
                        .font(.subheadline)
                    Button("打开 LocalDevVPN") {
                        guard let url = URL(string: "localdevvpn://") else { return }
                        UIApplication.shared.open(url) { opened in
                            if !opened {
                                Task { @MainActor in model.error = "无法打开 LocalDevVPN，请确认已安装并手动打开。" }
                            }
                        }
                    }
                    Button("检查定位服务") { Task { await model.checkConnection() } }
                        .disabled(model.busy || model.pairing || !model.hasPairing || model.needsRecovery)
                        .accessibilityIdentifier("probeService")
                    if model.busy { ProgressView("处理中…") }
                    Label(model.connectionText, systemImage: model.connectionReady ? "checkmark.circle" : "circle.dashed")
                        .foregroundStyle(model.connectionReady ? .green : .secondary)
                    Text("连接检查不修改位置。VPN 已连接与定位服务可用是两项独立检查。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.needsRecovery {
                        Text("请先停止模拟并确认真实位置恢复，再进行新的连接检查。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.error {
                    Section("当前提示") { Text(error).foregroundStyle(.red) }
                }
                Section("使用说明") {
                    Text("配对记录仅保存在这台 iPhone 的钥匙串中，不会上传。")
                    Text("运行时可切换到 Apple 地图检查当前位置蓝点。结束时点击“停止模拟”，确认真实位置恢复后点“已确认恢复”；若未恢复，可以再次停止。这里的地图图钉表示选中位置，停止后仍会保留。")
                    Text("本版本使用免费侧载及外部 LocalDevVPN。签名续期由安装工具负责。")
                }.font(.footnote)
            }
            .navigationTitle("连接这台 iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
