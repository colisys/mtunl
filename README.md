# MTunl

macOS 菜单栏 SSH 隧道管理工具。只包装系统 `/usr/bin/ssh`（以及可选的 `socat`），本质上是生成并守护连接命令，不实现 SSH 协议，也不持久化登录密码或私钥内容。可选密码仅在会话内存中使用。

## 功能

- 本地转发 `-L`（远程 → 本地）：把远程主机可访问的服务转发到本机端口。
- 远程转发 `-R`（本地 → 远程）：把本机可访问的服务转发到远程主机端口。
- 动态转发 `-D`（本地 → 远程）：在本机打开 SOCKS5 代理，流量经 SSH 连接从远程主机访问网络。
- socat 中继（本地 → 目标）：在本机监听 TCP 端口，并转发到另一个 TCP 地址（需自行安装 `socat`，如 `brew install socat`）。
- Mihomo TUN 流量接管：可选择现有动态 SSH 隧道作为 SOCKS5 出口，并指定需要接管的 IPv4 / IPv6 CIDR 网段。IPv4 使用 `IP-CIDR` 规则，IPv6 使用 `IP-CIDR6` 规则。下载与启动独立：先点击“下载内核”，缓存存在时按钮变为“更新内核”。更新检查最新 release tag；同 tag 且缓存可执行、`-v` 验证成功则不下载资产。启动始终不联网，本地路径优先，否则使用缓存。启动后通过 argv `-v` 查询实际版本（2 秒、16 KiB 上限），与缓存 release tag 分开显示。更新写入独立目录，不覆盖正在运行的二进制；更换已授权快照需要先停止 Mihomo，再重置 helper 授权。可配置 HTTPS 镜像前缀；镜像必须同时代理 Releases API JSON 和资产下载，留空使用 GitHub。
- 隧道配置保存在 `~/Library/Application Support/MTunl/tunnels.json`（权限 600）。私钥只存路径。
- 断线自动重连（1、2、4… 秒，最长 30 秒）；本地端口被占用时显示原因并重试。
- 守护进程 `mtunlctl serve` 独立于菜单栏界面运行，关闭界面不会断开隧道。
- 可选登录自启（用户级 LaunchAgent）。

## 认证与安全

- 默认使用密钥 / ssh-agent / `~/.ssh/config`，`BatchMode=yes`。可选“密钥优先 + 密码回退”：由 SSH 自行先尝试 agent/默认或指定密钥，再由编译的 PTY bridge 响应原生 password 提示，不依赖 sshpass。
- 密码只通过现有私有控制 socket 和匿名 stdin pipe 传递，不进入 argv、环境变量、命令预览、status、日志或外部文件。内存会话缓存支持重连，直至停止、删除、配置变化、认证失败或 daemon 退出。关闭 UI 不清除活跃 daemon 会话。
- 密码回退保留 SSH config、别名、ProxyJump/ProxyCommand。启动优先尝试密钥；密钥未成功，或服务端方法列表明确不提供 publickey 时,仅最终目标认证阶段明确提供 password 且出现身份匹配无回显提示才弹密码框（支持仅 password 的服务器）；网络/host-key 错误不会弹。支持跳板 agent/密钥 → 目标密码，不把目标密码交给跳板、MFA 或 passphrase。
- bridge 从真实主 SSH `-E` 详细日志实时读取目标认证身份与密码提示，只在身份与提示一致时响应；能力证据来自实际用户认证阶段的方法列表，不来自 `-G`、`-Q` 或传输握手。SSH 运行状态以明确认证成功事件为准，不再按存活时长判断。
- 用户 SSH 配置可执行本地命令，本来就是 SSH 的信任边界；上述识别不能保证 ProxyCommand 安全。不新增环境变量配置 helper；正常继承系统 `SSH_AUTH_SOCK`。不明确的目标身份/提示安全失败，密码缓存绑定最终 user/hostname/port。
- 所有连接使用 `StrictHostKeyChecking=yes`，不自动接受未知或变化主机密钥；首次使用需在独立终端核验指纹。详细安全边界、内存擦除限制、排错见 [FEATURES.md](FEATURES.md)。
- 监听地址默认 `127.0.0.1`。改成其他地址会让局域网设备访问该端口，界面会给出警告。
- MTunl 自身的启动参数以 argv 传给进程，不经过 shell（受信任 SSH 配置仍可能执行 shell 命令）；主机、用户、跳板机等字段拒绝以 `-` 开头的值，并在目标前加 `--`。
- 控制 socket 位于 `/tmp/mtunl-<uid>/ctl.sock`，目录和文件仅当前用户可访问，并校验对端 uid。

## 构建与运行

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh scripts/build-app.sh --adhoc-sign
open dist/MTunl.app
```

## CLI

```sh
mtunlctl list                      # 查看状态
mtunlctl start|stop|restart <名称或ID>
mtunlctl start-all | stop-all
mtunlctl reload                    # 重新读取配置
mtunlctl command <名称或ID>        # 只打印对应命令，不运行
mtunlctl install-agent | uninstall-agent
mtunlctl quit                      # 停止所有隧道并退出守护进程
```

### Mihomo 下载与镜像

`mtunlctl mihomo-download` 提交异步检查 / 下载任务，重复提交会去重；用 `mtunlctl mihomo-status` 查看完成或失败结果。下载失败不改变运行状态。

可选 `mirrorURL` / UI 镜像前缀必须是以 `/` 结尾的 HTTPS URL，不带认证、查询或片段。契约为直接拼接：`https://mirror.example/proxy/` + `https://api.github.com/repos/MetaCubeX/mihomo/releases/latest`，资产 URL 同理。不是替换主机，也不猜测供应商 API。留空直接访问 GitHub。镜像提供者可看到请求并提供可执行代码，请只使用可信服务；目前未验证发布签名 / 校验和。

新增状态字段可选，旧 daemon 可继续通信，但不会提供缓存 / 实际版本 / 更新进度，需要用户自行更新 daemon 才具备新能力。不会因这些字段升级协议而自动重启。

TUN 需要创建系统虚拟网卡并修改路由。首次启动通过 `osascript` 授权独立的 `mtunl-helper`，携带调用者 UID、daemon PID 和内核 SHA256；授权等待在后台执行，最长 120 秒，状态查询和停止请求不等待授权窗口。普通 start / stop 不重复请求管理员权限。SSH、下载、版本查询仍在用户 daemon 内执行。控制器绑定 loopback，使用 helper 随机生成的会话 secret。界面通过 `/configs` 的 `tun.enable` 检查 TUN 配置；这不等同于验证路由或真实流量已成功接管。若 Clash Party、VPN、WireGuard、Cloudflare WARP 或其他 Mihomo 实例已占用 TUN 路由，可能出现 `add route: ... file exists`；启动 MTunl 前应停止其他 TUN / Mihomo 实例。旧安装目录保留以保护运行中的内核，暂无自动清理。

### Privileged helper 会话与限制

- `mtunl-helper` 仅以 root 运行；用户 daemon / client 拒绝 root。helper socket 为 `/private/tmp/mtunl-helper-<uid>/helper.sock`，父目录 root 所有且用户不可写，socket 为调用者所有、0600；双方以 `getpeereid` 检查 UID，客户端必须看到 root 对端。
- **信任边界是同 UID，不是 app 身份**。同一用户的其他程序也能控制已授权会话。管理员授权信任当时的 helper 可执行文件和所选内核代码，不提供发布签名认证。内核首次授权时核对 SHA256，并复制到 root-only 会话目录；之后 IPC 不能指定 executable、任意文件路径、argv、shell 或 YAML。CIDR、端口及 auto-route 由类型化请求传递，helper 校验后生成固定 YAML。
- helper 和用户 daemon 均持有 `flock` singleton 锁，拒绝不安全的目录、锁和 socket。状态轮询不会启动、接管或重启其他现存进程。旧版本 daemon 不会被自动替换：请自行停止后再运行新版。
- helper 持有通往独立特权 watchdog 的管道租约；watchdog 是 Mihomo 的直接父进程。停止时关闭租约，watchdog 发送 TERM，2 秒后仍未退出则发送 KILL 并 waitpid 回收；helper 最多等待 4 秒，超时保留 ownership 并报告失败。信号只发给未回收的直属子进程，避免 PID 复用误杀。重复 start 返回现有实例，配置更改不会自动重启运行中的内核。
- `mtunlctl mihomo-helper-reset`（或面板重置按钮）仅在内核停止时退出 helper；下一次启动重新授权快照。下载新版本本身不撤销授权、不替换运行内核。
- helper 用 kqueue 监控原 daemon 的退出（包括 crash / SIGKILL），并在正常退出、TERM、INT、HUP 时清理内核、socket 和会话目录。**SIGKILL 无法捕获**：helper 自身被强杀或崩溃后，操作系统关闭管道，独立 watchdog 检测 EOF 后仍会执行 TERM → KILL 清理。watchdog 不持有 helper socket 或 singleton 锁，也不接受 IPC 命令；它与 helper 一并被 SIGKILL 时无法保证清理。强杀后的旧 root-only 会话目录可能残留，暂无自动回收；旧 socket 在下次授权启动时安全替换。锁文件有意保留以避免 inode 竞争。
- helper 内存保留最近 30 条内核输出（每条最多 300 字符），随状态回传；没有持久日志文件。授权失败时返回通用错误。没有安装 LaunchDaemon；会话不会跨 daemon 退出持续运行。

## 免责声明

本软件仅为开发者自用的流量转发工具，不提供、也不构成访问国际网络的信道或服务。使用者应自行了解并遵守所在地适用的法律法规、网络管理规定以及所使用网络和服务的条款。因使用本软件及其配置、转发连接或相关第三方组件产生的一切责任、风险和后果，均由使用者自行承担，开发者不提供任何明示或默示的合规性、可用性或适用性保证。

## 许可证

MTunl（包括 `MTunl`、`mtunlctl`、`mtunl-helper` 及 `TunnelCore`）采用 **GNU General Public License, version 3 or later（GPL-3.0-or-later）**。完整许可证文本见 [`LICENSE`](LICENSE)。

项目如果重新分发 Mihomo 内核，还必须同时保留 Mihomo 上游的版权声明和其适用的许可证文本；MTunl 的 GPL-3.0-or-later 不替代 Mihomo 或其他第三方组件各自的许可证。Mihomo 项目地址：<https://github.com/MetaCubeX/mihomo>。

如果只让用户选择或下载其自行获取的内核，MTunl 不会把 Mihomo 源码合并进本项目；如果发行包内附带内核，请在发行包中提供对应的第三方许可证和版权说明。

## 开发

- `Sources/TunnelCore`：配置模型与校验、命令生成、SSH / Mihomo 进程监督、Mihomo 官方内核下载与缓存、控制协议与 socket、LaunchAgent。
- `Sources/mtunlctl`：CLI 与用户守护进程入口。
- `Sources/mtunl-helper`：特权 helper 入口，构建脚本会一起打包 / 签名。
- `Sources/mtunl-ssh-bridge`：非特权、编译的 PTY SSH 密码桥，同目录打包 / 签名；缺失时密码启动安全失败。更新时需自行停止旧 daemon 并运行新版；旧 daemon 会拒绝新的 `startSession` 命令。
- `Sources/MTunl`：菜单栏界面。
- `Tests/TunnelCoreTests`：用 `sleep` / `false` 代替 ssh 测试监督逻辑，不建立真实连接。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -j 1
python3 scripts/test-ssh-bridge.py
```
