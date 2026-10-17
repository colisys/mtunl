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
    }

    func status(for config: TunnelConfig) -> TunnelStatus? { statuses[config.id] }

    func isActive(_ config: TunnelConfig) -> Bool {
        guard let state = statuses[config.id]?.state else { return false }
        return state != .stopped && state != .failed
    }

    func toggle(_ config: TunnelConfig, oneTimePassword: String? = nil) {
        send(isActive(config) ? "stop" : "start", target: config.id.uuidString, oneTimePassword: oneTimePassword)
    }

    func send(_ command: String, target: String? = nil, oneTimePassword: String? = nil) {
        let client = self.client
        Task {
            let result = await Task.detached {
                Result { try client.send(ControlRequest(command: command, target: target, oneTimePassword: oneTimePassword)) }
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
