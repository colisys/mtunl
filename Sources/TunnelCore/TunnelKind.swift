import Foundation

/// What a tunnel does. The first three are plain `ssh` forwards; `relay` is a
/// local `socat` TCP relay.
public enum TunnelKind: String, Codable, CaseIterable, Sendable {
    /// `ssh -L`: a service reachable from the remote host appears on a local port.
    case local
    /// `ssh -R`: a service reachable from this Mac appears on a remote port.
    case remote
    /// `ssh -D`: a local SOCKS5 proxy that exits on the remote host.
    case dynamic
    /// `socat`: relay a local TCP port to another TCP address.
    case relay

    /// User-facing name with the traffic direction expressed from the user's
    /// perspective, rather than from SSH's `-L`/`-R` naming.
    public var title: String {
        switch self {
        case .local: return "本地转发 (-L)：远程 → 本地"
        case .remote: return "远程转发 (-R)：本地 → 远程"
        case .dynamic: return "动态转发 (-D)：本地 → 远程（SOCKS5）"
        case .relay: return "socat 中继：本地 → 目标"
        }
    }

    public var directionDescription: String {
        switch self {
        case .local:
            return "把远程主机可访问的服务转发到本机端口。"
        case .remote:
            return "把本机可访问的服务转发到远程主机端口。"
        case .dynamic:
            return "在本机打开 SOCKS5 代理，流量经 SSH 连接从远程主机访问网络。"
        case .relay:
            return "在本机监听端口，并把连接转发到指定目标地址。"
        }
    }

    public var usesSSH: Bool { self != .relay }
    public var needsTarget: Bool { self != .dynamic }
    /// Whether the listening socket is opened on this Mac.
    public var listensLocally: Bool { self != .remote }
}
