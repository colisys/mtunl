import SwiftUI
import TunnelCore

struct TunnelMenuView: View {
    @ObservedObject var model: TunnelModel
    @State private var editing: TunnelConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let config = editing {
                TunnelEditor(
                    initial: config,
                    isNew: !model.configs.contains(where: { $0.id == config.id }),
                    save: { updated in
                        if model.upsert(updated) { editing = nil }
                    },
                    cancel: { editing = nil }
                )
            } else {
                list
            }

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("MTunl", systemImage: "arrow.left.arrow.right").font(.headline)
                Spacer()
                Circle()
                    .fill(model.daemonRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .help(model.daemonRunning ? "守护进程运行中" : "守护进程未运行")
                    .accessibilityLabel(model.daemonRunning ? "守护进程运行中" : "守护进程未运行")
                Button {
                    editing = TunnelConfig(name: "")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("新建隧道")
                .accessibilityLabel("新建隧道")
            }
            MihomoPanel(model: model)

            if model.configs.isEmpty {
                Text("还没有隧道，点右上角 + 新建。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.configs) { config in
                            TunnelRow(
                                config: config,
                                status: model.status(for: config),
                                active: model.isActive(config),
                                toggle: { model.toggle(config) },
                                edit: { editing = config },
                                copy: { model.copyCommand(config) },
                                delete: { model.delete(config) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("登录时自启", isOn: Binding(
                get: { model.agentInstalled },
                set: { model.setLoginStart($0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Spacer()
            Button("退出界面") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
                .help("只关闭菜单栏界面，隧道继续由守护进程运行")
            Button("全部停止并退出") { model.quitDaemonAndApp() }
                .controlSize(.small)
        }
    }
}

private struct TunnelRow: View {
    let config: TunnelConfig
    let status: TunnelStatus?
    let active: Bool
    let toggle: () -> Void
    let edit: () -> Void
    let copy: () -> Void
    let delete: () -> Void

    private var color: Color {
        switch status?.state {
        case .running: return .green
        case .starting, .waiting: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    private var stateText: String {
        guard let status else { return "未知" }
        switch status.state {
        case .stopped: return "已停止"
        case .starting: return "连接中…"
        case .running: return "运行中"
        case .waiting: return "重试中" + (status.retryIn.map { "（\($0) 秒）" } ?? "")
        case .failed: return "失败"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(config.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(stateText).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(active ? "停止" : "启动", action: toggle).controlSize(.small)
                Menu {
                    Button("编辑", action: edit)
                    Button("复制命令", action: copy)
                    Divider()
                    Button("删除", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("更多操作")
            }
            Text(config.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if config.exposesToNetwork {
                Label("监听 \(config.bindAddress)，局域网可访问", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let message = status?.message, status?.state != .running {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(status?.state == .failed ? .red : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
