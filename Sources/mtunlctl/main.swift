import Foundation
import Darwin
import TunnelCore

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
用法: mtunlctl <命令>
  serve                  前台运行守护进程（通常由 MTunl.app 或 LaunchAgent 启动）
  list | status          查看所有隧道状态
  start|stop|restart <名称或ID>
  start-all | stop-all
  reload                 让守护进程重新读取配置
  command <名称或ID>     只打印该隧道对应的命令，不运行
  install-agent          安装登录自启 LaunchAgent
  uninstall-agent        移除登录自启
  quit                   停止所有隧道并退出守护进程
  mihomo-download       异步检查 / 下载 Mihomo，使用 mihomo-status 查看结果，不启动它
  mihomo-start|mihomo-stop|mihomo-status
  mihomo-helper-reset   Stop first, then discard pinned helper binary authorization
"""

func selfPath() -> String {
    let path = CommandLine.arguments[0]
    if path.hasPrefix("/") { return path }
    return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardized.path
}

func send(_ command: String, target: String? = nil) -> ControlResponse {
    do {
        let response = try ControlClient().send(ControlRequest(command: command, target: target))
        if !response.success { fail("错误：\(response.error ?? "未知错误")") }
        return response
    } catch {
        fail("错误：\(error.localizedDescription)。请先运行 MTunl.app 或 mtunlctl serve。")
    }
}

func printStatuses(_ statuses: [TunnelStatus]?) {
    guard let statuses, !statuses.isEmpty else { print("没有隧道"); return }
    for status in statuses {
        var line = "\(status.name)\t\(status.state.rawValue)"
        if let pid = status.pid { line += "\tpid=\(pid)" }
        if let retry = status.retryIn { line += "\t\(retry) 秒后重试" }
        if let message = status.message { line += "\t\(message)" }
        print(line)
    }
}

func findConfig(_ target: String, in configs: [TunnelConfig]) -> TunnelConfig {
    if let id = UUID(uuidString: target), let found = configs.first(where: { $0.id == id }) { return found }
    let named = configs.filter { $0.name.caseInsensitiveCompare(target) == .orderedSame }
    guard named.count == 1 else { fail(named.isEmpty ? "找不到隧道：\(target)" : "名称不唯一：\(target)") }
    return named[0]
}

func serve() -> Never {
    guard getuid() != 0, geteuid() != 0 else { fail("User daemon must not run as root") }
    let store = ConfigStore()
    let supervisor = TunnelSupervisor()
    let configs: [TunnelConfig]
    do { configs = try store.load() } catch { fail("读取配置失败：\(error.localizedDescription)") }
    supervisor.apply(configs)

    let done = DispatchSemaphore(value: 0)
    let handler = ControlHandler(supervisor: supervisor, store: store) { done.signal() }
    let server = ControlServer(handler: handler)
    do { try server.start() } catch ControlServerError.alreadyRunning {
        print("守护进程已在运行")
        exit(0)
    } catch { fail("启动失败：\(error.localizedDescription)") }

    supervisor.startAutoStart()
    print("mtunl 守护进程已启动（\(configs.count) 条隧道）")

    var sources: [DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler { done.signal() }
        source.resume()
        sources.append(source)
    }
    done.wait()
    server.stop()
    handler.shutdown()
    supervisor.shutdown()
    withExtendedLifetime(sources) {}
    print("mtunl 守护进程已退出")
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { print(usage); exit(2) }
let target = arguments.count > 1 ? arguments[1] : nil

switch command {
case "serve":
    serve()
case "list", "status":
    printStatuses(send("status").statuses)
case "start", "stop", "restart":
    guard let target else { fail("缺少隧道名称或 ID", code: 2) }
    printStatuses(send(command, target: target).statuses)
case "start-all":
    printStatuses(send("startAll").statuses)
case "stop-all":
    printStatuses(send("stopAll").statuses)
case "reload":
    print(send("reload").message ?? "完成")
case "quit":
    print(send("shutdown").message ?? "完成")
case "mihomo-download", "mihomo-start", "mihomo-stop", "mihomo-status", "mihomo-helper-reset":
    let response = send(command)
    if let message = response.message { print(message) }
    if let mihomo = response.mihomo {
        if let version = mihomo.actualVersion { print("实际版本：\(version)") }
        if let error = mihomo.versionError { print(error) }
        if let kernel = mihomo.cachedKernel { print("缓存 release tag：\(kernel.version)") }
        if let message = mihomo.downloadMessage { print(message) }
        if let tunEnabled = mihomo.tunEnabled { print("TUN\t\(tunEnabled ? "已启用" : "未启用")") }
        if let tunError = mihomo.tunError { print(tunError) }
        print("Mihomo\t\(mihomo.state.rawValue)" + (mihomo.pid.map { "\tpid=\($0)" } ?? "") + (mihomo.message.map { "\t\($0)" } ?? ""))
    }
case "command":
    guard let target else { fail("缺少隧道名称或 ID", code: 2) }
    do {
        let config = findConfig(target, in: try ConfigStore().load())
        try config.validate()
        print(try CommandBuilder.command(for: config).shellString)
    } catch { fail("错误：\(error.localizedDescription)") }
case "install-agent":
    do {
        try LaunchAgent.install(executable: selfPath())
        print("已安装登录自启：\(LaunchAgent.plistURL.path)")
    } catch { fail("错误：\(error.localizedDescription)") }
case "uninstall-agent":
    do {
        try LaunchAgent.uninstall()
        print("已移除登录自启")
    } catch { fail("错误：\(error.localizedDescription)") }
case "-h", "--help", "help":
    print(usage)
default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
