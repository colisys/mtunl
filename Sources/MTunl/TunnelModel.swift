import AppKit
import Foundation
import TunnelCore

/// Bridges the UI to the daemon. Tunnels run in `mtunlctl serve`, so they keep
/// running if this app quits.
@MainActor
final class TunnelModel: ObservableObject {
    @Published private(set) var configs: [TunnelConfig] = []
    @Published private(set) var statuses: [UUID: TunnelStatus] = [:]
    @Published private(set) var daemonRunning = false
    @Published private(set) var agentInstalled = LaunchAgent.isInstalled
    @Published private(set) var mihomoSettings = (try? MihomoConfigStore().load()) ?? MihomoSettings()
    @Published private(set) var mihomoStatus = MihomoStatus()
    @Published var errorMessage: String?

    private let store = ConfigStore()
    private let client = ControlClient()
    private var pollTask: Task<Void, Never>?
    private var launching = false
    private static let statusPollInterval: UInt64 = 500_000_000

    init() {
        loadConfigs()
        ensureDaemon()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.statusPollInterval)
            }
        }
    }

    deinit { pollTask?.cancel() }

    private var daemonURL: URL? {
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mtunlctl")
        guard let url, FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    private func loadConfigs() {
        do { configs = try store.load() } catch {
            errorMessage = "读取配置失败：\(error.localizedDescription)"
        }
    }

    /// Starts the daemon detached from this app when nothing answers on the socket.
    func ensureDaemon() {
        guard !launching else { return }
        launching = true
        let client = self.client
        let url = daemonURL
        Task { [weak self] in
            let probe = await Task.detached { () -> ControlResponse? in
                try? client.send(ControlRequest(command: "ping"), timeout: 2)
            }.value
            let compatible = probe?.protocolVersion == ControlProtocol.version
            if !compatible {
                if probe != nil {
                    _ = try? client.send(ControlRequest(command: "shutdown"), timeout: 2)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                if let url {
                    let process = Process()
                    process.executableURL = url
                    process.arguments = ["serve"]
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    do { try process.run() } catch {
                        self?.errorMessage = "无法启动守护进程：\(error.localizedDescription)"
                    }
                } else {
                    self?.errorMessage = "找不到应用内的 mtunlctl，请使用打包脚本构建应用。"
                }
            }
            self?.launching = false
            await self?.refresh()
        }
    }

    func refresh() async {
        let client = self.client
        let response = await Task.detached { try? client.send(ControlRequest(command: "status"), timeout: 3) }.value
        guard let response, response.success, let list = response.statuses else {
            if daemonRunning { daemonRunning = false }
            ensureDaemon()
            return
        }
        daemonRunning = true
        if let mihomo = response.mihomo { mihomoStatus = mihomo }
        let map = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        if map != statuses { statuses = map }
        presentHostKeyRequest()
        presentPasswordRequest()
    }

    private var presentedPasswordRequests: Set<UUID> = []
    private var presentedHostKeyRequests: Set<UUID> = []
    private var requestAlertOpen = false

    private func presentHostKeyRequest() {
        guard !requestAlertOpen,
              let status = statuses.values.first(where: {
                  guard let request = $0.hostKey else { return false }
                  return !presentedHostKeyRequests.contains(request.requestID)
              }), let request = status.hostKey else { return }
        presentedHostKeyRequests.insert(request.requestID)
        requestAlertOpen = true
        defer { requestAlertOpen = false }
        let alert = NSAlert()
        alert.messageText = "首次连接 \(request.host)"
        alert.informativeText = "请核对服务器指纹 \(request.fingerprint) 与管理员提供的一致后再信任。"
        alert.addButton(withTitle: "信任并连接")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard statuses[status.id]?.hostKey?.requestID == request.requestID else { return }
        if response == .alertFirstButtonReturn {
            send("trustHostKey", target: status.id.uuidString, hostKeyRequestID: request.requestID)
        } else {
            send("stop", target: status.id.uuidString)
        }
    }

    private func presentPasswordRequest() {
        guard !requestAlertOpen,
              let status = statuses.values.first(where: {
                  guard let token = $0.passwordRequestID else { return false }
                  return !presentedPasswordRequests.contains(token)
              }), let token = status.passwordRequestID else { return }
        presentedPasswordRequests.insert(token)
        requestAlertOpen = true
        defer { requestAlertOpen = false }
        let alert = NSAlert()
        alert.messageText = "目标 SSH 需要登录密码"
        alert.informativeText = "\(status.name) 的密钥认证未通过，服务器支持密码登录。密码仅保存在内存中，停止或认证失败后清除。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "继续认证")
        alert.addButton(withTitle: "取消并停止")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let password = field.stringValue
        field.stringValue = ""
        guard statuses[status.id]?.passwordRequestID == token else { return }
        if response == .alertFirstButtonReturn && !password.isEmpty {
            send("startSession", target: status.id.uuidString, oneTimePassword: password, passwordRequestID: token)
        } else {
            send("stop", target: status.id.uuidString)
        }
    }

    func status(for config: TunnelConfig) -> TunnelStatus? { statuses[config.id] }

    func isActive(_ config: TunnelConfig) -> Bool {
        guard let state = statuses[config.id]?.state else { return false }
        return state != .stopped && state != .failed
    }

    func toggle(_ config: TunnelConfig, oneTimePassword: String? = nil) {
        send(isActive(config) ? "stop" : "start", target: config.id.uuidString, oneTimePassword: oneTimePassword)
    }

    func send(_ command: String, target: String? = nil, oneTimePassword: String? = nil,
              passwordRequestID: UUID? = nil, hostKeyRequestID: UUID? = nil) {
        let client = self.client
        Task {
            let result = await Task.detached {
                Result { try client.send(ControlRequest(command: command, target: target, oneTimePassword: oneTimePassword,
                                                        passwordRequestID: passwordRequestID, hostKeyRequestID: hostKeyRequestID)) }
            }.value
            switch result {
            case .success(let response):
                if !response.success { errorMessage = response.error }
                else {
                    if let mihomo = response.mihomo { mihomoStatus = mihomo }
                    if let list = response.statuses {
                        statuses = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
                    }
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Persists the edited list, then tells the daemon to re-read it.
    @discardableResult
    func save(_ updated: [TunnelConfig]) -> Bool {
        do {
            try store.save(updated)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        configs = updated
        errorMessage = nil
        send("reload")
        return true
    }

    func upsert(_ config: TunnelConfig) -> Bool {
        var list = configs
        if let index = list.firstIndex(where: { $0.id == config.id }) { list[index] = config } else { list.append(config) }
        return save(list)
    }

    func delete(_ config: TunnelConfig) {
        save(configs.filter { $0.id != config.id })
    }

    func copyCommand(_ config: TunnelConfig) {
        do {
            try config.validate()
            let text = try CommandBuilder.command(for: config).shellString
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Opens an interactive SSH session in Terminal.app using the tunnel's
    /// connection settings; the running forward is not reused or affected.
    func openTerminalSession(_ config: TunnelConfig) {
        do {
            try config.validate()
            let command = try CommandBuilder.terminalSession(for: config)
            let script = "tell application \"Terminal\"\n"
                + "    activate\n"
                + "    do script \(Self.escapedAppleScriptString(command.shellString))\n"
                + "end tell"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try process.run()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func escapedAppleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    func saveMihomo(_ settings: MihomoSettings) {
        do {
            try MihomoConfigStore().save(settings)
            mihomoSettings = settings
            send("reload")
        } catch { errorMessage = error.localizedDescription }
    }

    func downloadMihomo() {
        guard mihomoStatus.downloadInProgress != true else { return }
        send("mihomo-download")
    }

    func toggleMihomo() {
        if mihomoStatus.state == .running && mihomoStatus.tunEnabled == false {
            send("mihomo-restart")
        } else {
            send(mihomoStatus.state == .stopped || mihomoStatus.state == .failed ? "mihomo-start" : "mihomo-stop")
        }
    }

    func setLoginStart(_ enabled: Bool) {
        do {
            if enabled {
                guard let url = daemonURL else { throw TunnelValidationError("找不到应用内的 mtunlctl") }
                try LaunchAgent.install(executable: url.path)
            } else {
                try LaunchAgent.uninstall()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        agentInstalled = LaunchAgent.isInstalled
    }

    func quitDaemonAndApp() {
        let client = self.client
        Task.detached { _ = try? client.send(ControlRequest(command: "shutdown"), timeout: 3) }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApplication.shared.terminate(nil)
        }
    }
}
