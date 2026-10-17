import SwiftUI
import TunnelCore

/// Edits a copy of a tunnel. Ports are held as text so a half-typed value
/// never turns into a bogus number; `validate()` has the final say on save.
struct TunnelEditor: View {
    let isNew: Bool
    let save: (TunnelConfig) -> Void
    let cancel: () -> Void

    @State private var config: TunnelConfig
    @State private var listenPort: String
    @State private var targetPort: String
    @State private var sshPort: String
    @State private var user: String
    @State private var identity: String
    @State private var jump: String
    @State private var error: String?

    init(initial: TunnelConfig, isNew: Bool, save: @escaping (TunnelConfig) -> Void, cancel: @escaping () -> Void) {
        self.isNew = isNew
        self.save = save
        self.cancel = cancel
        _config = State(initialValue: initial)
        _listenPort = State(initialValue: initial.listenPort > 0 ? String(initial.listenPort) : "")
        _targetPort = State(initialValue: initial.targetPort > 0 ? String(initial.targetPort) : "")
        _sshPort = State(initialValue: initial.sshPort.map(String.init) ?? "")
        _user = State(initialValue: initial.user ?? "")
        _identity = State(initialValue: initial.identityFile ?? "")
        _jump = State(initialValue: initial.jumpHost ?? "")
    }

    private var listenLabel: String {
        switch config.kind {
        case .remote: return "远程监听（本地 → 远程）"
        case .local: return "本地监听（远程 → 本地）"
        case .dynamic: return "本地 SOCKS 监听（本地 → 远程）"
        case .relay: return "本地监听（本地 → 目标）"
        }
    }

    private var targetPlaceholder: String {
        switch config.kind {
        case .remote: return "本地目标主机"
        case .local: return "远程目标主机"
        case .relay: return "目标主机"
        case .dynamic: return "目标主机"
        }
    }

    private var preview: String? {
        guard let built = build(), (try? built.validate()) != nil else { return nil }
        return try? CommandBuilder.command(for: built).shellString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isNew ? "新建隧道" : "编辑隧道").font(.headline)
            TextField("名称", text: $config.name).textFieldStyle(.roundedBorder).controlSize(.small)
            Picker("类型", selection: $config.kind) {
                ForEach(TunnelKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .controlSize(.small)
            Text(config.kind.directionDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if config.kind.usesSSH {
                TextField("SSH 主机或 ~/.ssh/config 别名", text: $config.host)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                HStack(spacing: 6) {
                    TextField("用户（可选）", text: $user).textFieldStyle(.roundedBorder)
                    TextField("端口", text: $sshPort).textFieldStyle(.roundedBorder).frame(width: 64)
                }
                .controlSize(.small)
                
                Picker("认证方式", selection: $config.sshAuthMethod) {
                    ForEach(SSHAuthMethod.allCases, id: \.self) { method in
                        Text(method == .password ? "密钥优先 + 密码回退" : "Agent / 密钥").tag(method)
                    }
                }
                .controlSize(.small)
                .pickerStyle(.segmented)
                
                if config.sshAuthMethod == .privateKey {
                    TextField("私钥路径（可选）", text: $identity)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                    Text("若私钥已加密，请提前运行 ssh-add 添加到 SSH agent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("沿用 SSH config 与跳板配置。先尝试密钥/agent，失败且目标支持密码时才询问；跳板仅用密钥/agent。首次连接请先在终端核验主机指纹。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                TextField("跳板机（可选，如 user@bastion）", text: $jump)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
            }

            HStack(spacing: 6) {
                TextField("\(listenLabel)地址", text: $config.bindAddress).textFieldStyle(.roundedBorder)
                TextField("端口", text: $listenPort).textFieldStyle(.roundedBorder).frame(width: 64)
            }
            .controlSize(.small)

            if config.kind.needsTarget {
                HStack(spacing: 6) {
                    TextField(targetPlaceholder, text: $config.targetHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("端口", text: $targetPort).textFieldStyle(.roundedBorder).frame(width: 64)
                }
                .controlSize(.small)
            }

            Toggle("守护进程启动时自动开启", isOn: $config.autoStart)
                .toggleStyle(.checkbox).controlSize(.small)

            if config.exposesToNetwork {
                Label("非回环地址会让局域网其他设备访问这个端口", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let preview {
                Text(preview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", action: cancel)
                    .controlSize(.small)
                    .foregroundStyle(.white)
                Button("保存") { commit() }
                    .controlSize(.small)
                    .foregroundStyle(.white)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func port(_ text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private func build() -> TunnelConfig? {
        var result = config
        result.name = config.name.trimmingCharacters(in: .whitespaces)
        result.listenPort = port(listenPort)
        result.targetPort = config.kind.needsTarget ? port(targetPort) : 0
        if !config.kind.needsTarget { result.targetHost = "" }
        let trimmedPort = sshPort.trimmingCharacters(in: .whitespaces)
        result.sshPort = trimmedPort.isEmpty ? nil : Int(trimmedPort) ?? 0
        result.user = user.isEmpty ? nil : user.trimmingCharacters(in: .whitespaces)
        result.identityFile = identity.isEmpty ? nil : identity.trimmingCharacters(in: .whitespaces)
        result.jumpHost = jump.isEmpty ? nil : jump.trimmingCharacters(in: .whitespaces)
        if !config.kind.usesSSH {
            result.host = ""
            result.user = nil
            result.sshPort = nil
            result.identityFile = nil
            result.jumpHost = nil
        }
        return result
    }

    private func commit() {
        guard let built = build() else { return }
        do {
            try built.validate()
            error = nil
            save(built)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
