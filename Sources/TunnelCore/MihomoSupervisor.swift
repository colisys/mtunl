import Foundation
import Darwin

/// Downloads stay in the user daemon; only the pinned kernel runs in the helper.
public final class MihomoSupervisor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mtunl.mihomo.state")
    private let operations = DispatchQueue(label: "mtunl.mihomo.operations")
    private var settings = MihomoSettings()
    private var tunnels: [TunnelConfig] = []
    private var status = MihomoStatus()
    private var cachedKernel: MihomoKernelInfo?
    private var downloading = false
    private var downloadMessage: String?
    private var generation = 0
    private var poller: DispatchSourceTimer?
    private var localOwner: OwnedMihomo?
    private let kernelManager: MihomoKernelManager
    private let authorizeTUN: Bool
    private let homeDirectory: URL
    private let client: HelperTransport
    private var controllerSecret: String?

    public convenience init(kernelManager: MihomoKernelManager = MihomoKernelManager()) {
        self.init(kernelManager: kernelManager, authorizeTUN: true)
    }
    public convenience init(kernelManager: MihomoKernelManager, authorizeTUN: Bool,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(kernelManager: kernelManager, authorizeTUN: authorizeTUN, homeDirectory: homeDirectory,
                  client: PrivilegedClient(uid: getuid()))
    }
    init(kernelManager: MihomoKernelManager, authorizeTUN: Bool, homeDirectory: URL, client: HelperTransport) {
        self.client = client
        self.kernelManager = kernelManager
        self.authorizeTUN = authorizeTUN
        self.homeDirectory = homeDirectory
        cachedKernel = kernelManager.cachedInfo()
    }
    public func apply(settings: MihomoSettings, tunnels: [TunnelConfig]) {
        queue.sync { self.settings = settings; self.tunnels = tunnels }
    }
    public func start() {
        let input: (MihomoSettings, [TunnelConfig], Int)? = queue.sync {
            guard status.state != .running, status.state != .starting else { return nil }
            generation += 1
            status = MihomoStatus(state: .starting, message: "正在连接 / 授权 Mihomo helper…")
            return (settings, tunnels, generation)
        }
        guard let (settings, tunnels, token) = input else { return }
        operations.async { [self] in
            do {
                let dynamic = try MihomoConfigBuilder.validate(settings, tunnels: tunnels)
                let config = HelperConfiguration(cidrs: settings.cidrs, mixedPort: settings.mixedPort,
                    controllerPort: settings.controllerPort, socksPort: dynamic.listenPort, autoRoute: settings.autoRoute)
                _ = try config.yaml()
                let binary = URL(fileURLWithPath: try kernelManager.resolveBinary(override: settings.binaryPath.isEmpty ? nil : settings.binaryPath).path)
                let result: MihomoStatus
                if authorizeTUN {
                    let digest = try PrivilegedClient.digest(binary)
                    if let existing = try? client.send(HelperRequest(operation: .status)) {
                        guard existing.digest == digest else {
                            throw MihomoError.process("Helper pinned another binary. Stop Mihomo and use mihomo-helper-reset before authorizing the new binary.")
                        }
                    } else {
                        try client.authorize(binary: binary, digest: digest)
                    }
                    guard queue.sync(execute: { generation == token }) else { return }
                    let response = try client.send(HelperRequest(operation: .status))
                    guard response.digest == digest else { throw MihomoError.process("Helper binary mismatch") }
                    let started = try client.send(HelperRequest(operation: .start, configuration: config))
                    result = started.status
                    controllerSecret = started.controllerSecret
                } else {
                    let directory = homeDirectory.appendingPathComponent("mihomo-test")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let owner = OwnedMihomo(binary: binary, directory: directory)
                    localOwner = owner
                    result = try owner.start(config)
                    controllerSecret = owner.controllerSecret
                }
                var snapshot = result
                // Version probing remains unprivileged and bounded.
                do { snapshot.actualVersion = try MihomoKernelManager.actualVersion(at: binary.path) }
                catch { snapshot.versionError = error.localizedDescription }
                queue.sync {
                    guard generation == token else { return }
                    status = snapshot
                }
                beginPolling(port: settings.controllerPort, token: token)
            } catch {
                queue.sync {
                    if generation == token { status = MihomoStatus(state: .failed, message: error.localizedDescription) }
                }
            }
        }
    }
    public func stop() {
        let token = queue.sync { () -> Int in
            generation += 1; poller?.cancel(); poller = nil
            status = MihomoStatus(state: .stopped, message: "正在停止 Mihomo…")
            return generation
        }
        operations.async { [self] in
            do {
                let snapshot: MihomoStatus
                if authorizeTUN {
                    snapshot = try client.send(HelperRequest(operation: .stop)).status
                } else { snapshot = try localOwner?.stop() ?? MihomoStatus() }
                queue.sync { if generation == token { status = snapshot } }
            } catch {
                queue.sync { if generation == token { status = MihomoStatus(state: .failed, message: error.localizedDescription) } }
            }
        }
    }
    /// Explicit consent to discard the authorized binary; never silently restarts a live kernel.
    public func resetHelper() {
        operations.async { [self] in
            do {
                let response = try client.send(HelperRequest(operation: .status))
                guard response.status.state != .running else { throw MihomoError.process("Stop Mihomo before resetting helper") }
                _ = try client.send(HelperRequest(operation: .shutdown))
                queue.sync { status = MihomoStatus() }
            } catch { queue.sync { status.message = error.localizedDescription } }
        }
    }
    public func shutdown() {
        queue.sync { generation += 1; poller?.cancel(); poller = nil }
        // The helper also monitors daemon exit, including SIGKILL/crashes.
        if authorizeTUN { _ = try? client.send(HelperRequest(operation: .shutdown)) }
        else { operations.sync { _ = try? localOwner?.stop() } }
    }
    private func beginPolling(port: Int, token: Int) {
        queue.sync {
            guard generation == token else { return }
            poller?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: operations)
            timer.schedule(deadline: .now() + 1, repeating: 5)
            timer.setEventHandler { [weak self] in
                guard let self, self.queue.sync(execute: { self.generation == token }) else { return }
                do {
                    let snapshot = self.authorizeTUN ? try self.client.send(HelperRequest(operation: .status)).status : self.localOwner?.snapshot() ?? MihomoStatus()
                    self.queue.sync {
                        guard self.generation == token else { return }
                        self.status.state = snapshot.state; self.status.pid = snapshot.pid
                                                self.status.log = snapshot.log
                        if snapshot.state != .running { self.status.message = snapshot.message }
                    }
                    if snapshot.state == .running { self.probe(port: port, token: token) }
                } catch {
                    self.queue.sync {
                        if self.generation == token { self.status = MihomoStatus(state: .failed, message: error.localizedDescription) }
                    }
                }
            }
            poller = timer; timer.resume()
        }
    }
    private func probe(port: Int, token: Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/configs")!)
        request.timeoutInterval = 2
        if let controllerSecret { request.setValue("Bearer \(controllerSecret)", forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            let result = Result { () throws -> Bool in
                if let error { throw error }
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else { throw MihomoError.process("Invalid controller response") }
                return try Self.decodeTUNEnabled(data)
            }
            self?.queue.async { [weak self] in
                guard let self, self.generation == token, self.status.state == .running else { return }
                switch result {
                case .success(let enabled):
                    self.status.tunEnabled = enabled
                    self.status.tunError = enabled ? nil : "Mihomo 运行中，但 TUN 未启用"
                case .failure(let error):
                    self.status.tunEnabled = nil; self.status.tunError = error.localizedDescription
                }
            }
        }.resume()
    }
    static func decodeTUNEnabled(_ data: Data) throws -> Bool {
        struct Configuration: Decodable {
            struct TUN: Decodable { let enable: Bool }
            let tun: TUN
        }
        return try JSONDecoder().decode(Configuration.self, from: data).tun.enable
    }
    public func downloadKernel() {
        queue.sync {
            guard !downloading else { return }
            downloading = true; downloadMessage = "正在检查最新版本…"
            let mirror = settings.mirrorURL
            let previous = cachedKernel
            DispatchQueue.global(qos: .utility).async { [self] in
                let result = Result { try kernelManager.downloadLatestKernel(mirrorURL: mirror) }
                queue.async { [self] in
                    downloading = false
                    switch result {
                    case .success(let info):
                        cachedKernel = info
                        downloadMessage = previous == info ? "已是最新版本 \(info.version)" : "已下载 \(info.version)；更换 helper 快照需停止并重置授权"
                    case .failure(let error): downloadMessage = error.localizedDescription
                    }
                }
            }
        }
    }
    public func currentStatus() -> MihomoStatus {
        queue.sync {
            var snapshot = status
            snapshot.cachedKernel = cachedKernel
            snapshot.downloadInProgress = downloading
            snapshot.downloadMessage = downloadMessage
            return snapshot
        }
    }
}
