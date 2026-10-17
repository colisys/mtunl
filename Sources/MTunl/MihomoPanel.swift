import AppKit
import SwiftUI
import TunnelCore

struct MihomoPanel: View {
    @ObservedObject var model: TunnelModel
    @State private var path: String
    @State private var mirror: String
    @State private var cidrs: String
    @State private var mixedPort: String
    @State private var selectedTunnel: UUID?
    @State private var expanded = false

    init(model: TunnelModel) {
        self.model = model
        let settings = model.mihomoSettings
        _path = State(initialValue: settings.binaryPath)
        _mirror = State(initialValue: settings.mirrorURL)
        _cidrs = State(initialValue: settings.cidrs.joined(separator: ", "))
        _mixedPort = State(initialValue: String(settings.mixedPort))
        _selectedTunnel = State(initialValue: settings.dynamicTunnelID)
    }

    private var dynamicTunnels: [TunnelConfig] {
        model.configs.filter { $0.kind == .dynamic }
    }

    private var statusText: String {
        switch model.mihomoStatus.state {
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .running: return model.mihomoStatus.captureStatusText
        case .failed: return "失败"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "network").font(.caption)
                    Text("流量接管（Mihomo TUN）").font(.caption.weight(.medium))
                    Spacer()
                    Text(statusText).font(.caption2).foregroundStyle(model.mihomoStatus.state == .running && model.mihomoStatus.tunEnabled == true ? .green : .secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {

                    HStack(spacing: 6) {
                        TextField("内核路径覆盖（留空使用缓存）", text: $path)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { chooseBinary() }
                            .controlSize(.small)
                    }
                    .controlSize(.small)

                    TextField("可选 HTTPS 镜像前缀", text: $mirror)
                        .textFieldStyle(.roundedBorder).controlSize(.small)

                    if let version = model.mihomoStatus.actualVersion {
                        Text("运行内核版本：\(version)").font(.caption2)
                    }
                    if let error = model.mihomoStatus.versionError {
                        Text(error).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let kernel = model.mihomoStatus.cachedKernel {
                        Text("缓存 release tag：\(kernel.version)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Picker("SSH SOCKS 出口", selection: $selectedTunnel) {
                        Text("选择动态隧道").tag(UUID?.none)
                        ForEach(dynamicTunnels) { tunnel in
                            Text(tunnel.name).tag(UUID?.some(tunnel.id))
                        }
                    }
                    .labelsHidden().controlSize(.small)
                    TextField("CIDR 网段（逗号分隔，如 10.0.0.0/8, 2001:db8::/32）", text: $cidrs)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                    HStack(spacing: 6) {
                        Text("混合端口").font(.caption2).foregroundStyle(.secondary)
                        TextField("17890", text: $mixedPort).textFieldStyle(.roundedBorder).frame(width: 64)
                        Spacer()
                        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(model.mihomoStatus.downloadButtonTitle) { model.downloadMihomo() }
                                .disabled(model.mihomoStatus.downloadInProgress == true)
                                .controlSize(.small)
                                .fixedSize()
                        }
                        Button { 
                            model.toggleMihomo()
                        } label: {
                            Text(model.mihomoStatus.state == .running && model.mihomoStatus.tunEnabled == false ? "重新启动" : (model.mihomoStatus.state == .running || model.mihomoStatus.state == .starting ? "停止" : "启动"))
                                .frame(minWidth: 34)
                        }
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(model.mihomoStatus.state == .failed && selectedTunnel == nil)
                    }
                    Button("重置授权") { model.send("mihomo-helper-reset") }
                        .controlSize(.small)
                        .disabled(model.mihomoStatus.state == .running || model.mihomoStatus.state == .starting)

                    if let message = model.mihomoStatus.downloadMessage {
                        Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if let error = model.mihomoStatus.tunError {
                        Text(error).font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.mihomoStatus.tunEnabled != true,
                       let message = model.mihomoStatus.message {
                        Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.leading, 16)
                .onChange(of: path) { _ in save() }
                .onChange(of: mirror) { _ in save() }
                .onChange(of: cidrs) { _ in save() }
                .onChange(of: mixedPort) { _ in save() }
                .onChange(of: selectedTunnel) { _ in save() }
            }
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.title = "选择 Mihomo 可执行文件"
        panel.message = "选择本机已有的 Mihomo 内核；选择后不会自动下载。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func save() {
        let values = cidrs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let settings = MihomoSettings(
            enabled: true,
            binaryPath: path.trimmingCharacters(in: .whitespacesAndNewlines),
            mirrorURL: mirror.trimmingCharacters(in: .whitespacesAndNewlines),
            dynamicTunnelID: selectedTunnel,
            cidrs: values,
            mixedPort: Int(mixedPort) ?? 17890,
            controllerPort: model.mihomoSettings.controllerPort,
            autoRoute: true
        )
        model.saveMihomo(settings)
    }
}
