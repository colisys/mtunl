import Foundation

/// Turns a `ControlRequest` into supervisor actions. Kept free of sockets so it
/// can be tested directly.
public final class ControlHandler: @unchecked Sendable {
    private let supervisor: TunnelSupervisor
    private let store: ConfigStore
    private let mihomoStore: MihomoConfigStore
    private let mihomo: MihomoSupervisor
    private let onShutdown: @Sendable () -> Void

    public init(supervisor: TunnelSupervisor, store: ConfigStore,
                mihomo: MihomoSupervisor = MihomoSupervisor(),
                mihomoStore: MihomoConfigStore = MihomoConfigStore(),
                onShutdown: @escaping @Sendable () -> Void) {
        self.supervisor = supervisor
        self.store = store
        self.mihomo = mihomo
        self.mihomoStore = mihomoStore
        self.onShutdown = onShutdown
        let settings = (try? mihomoStore.load()) ?? MihomoSettings()
        mihomo.apply(settings: settings, tunnels: (try? store.load()) ?? [])
    }

    public func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.command {
        case "ping":
            return ControlResponse(success: true, message: "pong", mihomo: mihomo.currentStatus())
        case "status":
            return ControlResponse(success: true, statuses: supervisor.statuses(), mihomo: mihomo.currentStatus())
        case "mihomo-download":
            do {
                mihomo.apply(settings: try mihomoStore.load(), tunnels: try store.load())
                mihomo.downloadKernel()
                return ControlResponse(success: true, message: "下载 / 更新任务已接受，请查询 mihomo-status",
                                       mihomo: mihomo.currentStatus())
            } catch {
                return ControlResponse(success: false, error: error.localizedDescription)
            }
        case "mihomo-start":
            do {
                let settings = try mihomoStore.load()
                mihomo.apply(settings: settings, tunnels: try store.load())
                if let id = settings.dynamicTunnelID {
                    guard let tunnel = (try store.load()).first(where: { $0.id == id }) else {
                        return ControlResponse(success: false, error: MihomoError.tunnelNotFound.localizedDescription,
                                               mihomo: mihomo.currentStatus())
                    }
                    guard tunnel.kind == .dynamic else {
                        return ControlResponse(success: false, error: MihomoError.tunnelMustBeDynamic.localizedDescription,
                                               mihomo: mihomo.currentStatus())
                    }
                    supervisor.start(id)
                }
                mihomo.start()
                return ControlResponse(success: mihomo.currentStatus().state != .failed,
                                       error: mihomo.currentStatus().message,
                                       mihomo: mihomo.currentStatus())
            } catch {
                return ControlResponse(success: false, error: "读取 Mihomo 配置失败：\(error.localizedDescription)",
                                       mihomo: mihomo.currentStatus())
            }
        case "mihomo-restart":
            mihomo.stop()
            do {
                let settings = try mihomoStore.load()
                let tunnels = try store.load()
                mihomo.apply(settings: settings, tunnels: tunnels)
                mihomo.start()
                return ControlResponse(success: mihomo.currentStatus().state != .failed,
                                       error: mihomo.currentStatus().message,
                                       mihomo: mihomo.currentStatus())
            } catch {
                return ControlResponse(success: false, error: "重新启动 Mihomo 失败：\(error.localizedDescription)",
                                       mihomo: mihomo.currentStatus())
            }
        case "mihomo-helper-reset":
                    mihomo.resetHelper()
                    return ControlResponse(success: true, message: "Helper reset requested; query mihomo-status")
                case "mihomo-stop":
            mihomo.stop()
            return ControlResponse(success: true, message: "Mihomo 停止请求已接受", mihomo: mihomo.currentStatus())
        case "mihomo-status":
            return ControlResponse(success: true, mihomo: mihomo.currentStatus())
        case "reload":
            do {
                let tunnels = try store.load()
                supervisor.apply(tunnels)
                let settings = try mihomoStore.load()
                mihomo.apply(settings: settings, tunnels: tunnels)
                return ControlResponse(success: true, message: "已重新加载配置", statuses: supervisor.statuses(), mihomo: mihomo.currentStatus())
            } catch {
                return ControlResponse(success: false, error: "读取配置失败：\(error.localizedDescription)")
            }
        case "startAll":
            supervisor.startAll()
            return ControlResponse(success: true, statuses: supervisor.statuses(), mihomo: mihomo.currentStatus())
        case "stopAll":
            supervisor.stopAll()
            return ControlResponse(success: true, statuses: supervisor.statuses(), mihomo: mihomo.currentStatus())
        case "start", "stop", "restart":
            return perform(request)
        case "shutdown":
            mihomo.stop()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [onShutdown] in onShutdown() }
            return ControlResponse(success: true, message: "正在退出")
        default:
            return ControlResponse(success: false, error: "未知命令：\(request.command)")
        }
    }

    public func shutdown() { mihomo.shutdown() }

    private func perform(_ request: ControlRequest) -> ControlResponse {
        guard let target = request.target, !target.isEmpty else {
            return ControlResponse(success: false, error: "缺少隧道名称或 ID")
        }
        let statuses = supervisor.statuses()
        let match: TunnelStatus
        if let id = UUID(uuidString: target), let found = statuses.first(where: { $0.id == id }) {
            match = found
        } else {
            let named = statuses.filter { $0.name.caseInsensitiveCompare(target) == .orderedSame }
            guard named.count == 1, let found = named.first else {
                return ControlResponse(success: false, error: named.isEmpty ? "找不到隧道：\(target)" : "名称不唯一：\(target)")
            }
            match = found
        }
        switch request.command {
        case "start": supervisor.start(match.id)
        case "stop": supervisor.stop(match.id)
        default: supervisor.restart(match.id)
        }
        return ControlResponse(success: true, statuses: supervisor.statuses(), mihomo: mihomo.currentStatus())
    }
}
