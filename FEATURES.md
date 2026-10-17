# MTunl 使用指南

## SSH 配置、认证顺序和按需密码

MTunl 保留系统 SSH、`~/.ssh/config`、别名、IdentityAgent、IdentityFile、ProxyJump（含多跳）及 ProxyCommand 配置。不再使用 `-F /dev/null` 隔离配置，也不覆盖 ProxyCommand/ProxyJump 为 none。SSH 配置本来就是执行 SSH 的信任边界：`Match exec`、ProxyCommand、LocalCommand 等可运行本地命令，必须由用户信任。认证识别**不能证明 ProxyCommand 安全**，也不是对用户配置的沙箱。

### Agent / 密钥模式

以 `BatchMode=yes` 运行，OpenSSH 使用有效配置中的 agent、默认/指定密钥。不会以 identity 路径是否为空判断 agent 可用性，指定 `-i` 不额外强制 `IdentitiesOnly=yes`（用户配置自身的限制仍然生效）。加密私钥请提前用 `ssh-add` 解锁。

### 密钥优先 + 密码回退模式

1. 编辑器选择“密钥优先 + 密码回退”。点击启动**不立即弹密码框**，先运行真实隧道 SSH。
2. bridge 从主 SSH 的 `-E` 详细日志实时读取最终目标身份（`Authenticating to HOST:PORT as 'USER'`）和密码提示（`USER@HOST's password: `），不使用 `ssh -G`。
3. 仅当下列证据同时存在时请求密码：主 SSH 已输出最终目标认证上下文；实际选择过 publickey，或服务端当前认证方法列表明确不包含 publickey；服务端认证阶段公布的方法列表仍允许 password；主 SSH 已进入 password 方法；PTY 出现与该上下文一致的 `user@hostname's password: ` 标准无回显提示。此时无密码的连接结束，daemon 发布一次性请求 ID，UI 才弹框。
4. 用户确认后重新启动隧道并重新核实身份与认证阶段。第二次仍优先使用服务端允许的密钥认证；若密钥认证成功，密码不会发送。若输入期间停止、删除或修改配置，请求 ID 失效，拒绝迟到响应。取消会停止隧道。
5. agent 成功不会弹框。网络错误、主机密钥错误、无 password 方法、跳板密码提示、身份/诊断不明确也不会弹目标密码框。

**不是握手探测**：`-v` 的 `Authentications that can continue` 是实际连接中服务端在用户认证阶段提供的方法列表，不是传输握手能力。没有额外的网络 probe，第一次尝试就是实际隧道进程。目标身份与方法证据全部来自这一个实际 SSH 进程。

### 跳板与身份来源

- 支持“跳板 agent/密钥认证 → 最终目标密码认证”。显式 `-J` 和配置中的 ProxyJump 都保留；ProxyCommand 也保留但必须信任。
- 主 SSH 用 `-v -E /dev/fd/1` 将诊断写入匿名 stdout pipe（`-N` 无远端 stdout），与跳板子 SSH 的 stderr 分离。这里 `/dev/fd/1` 是已有匿名管道描述符，不是外部日志文件。不能使用任意大于 2 的继承 fd：OpenSSH 启动时会关闭它们。
- 密码提示必须与主 SSH `-E` 日志里最终目标的 `Authenticating to` 上下文一致；跳板阶段的提示出现在该上下文之前，因此一律拒绝，即使与目标同名。
- 密码缓存绑定最初请求的 user/hostname/port，配置改变目标时清理。bridge 在实际 `Authenticating to` 行与绑定不一致时拒绝发送。该绑定不证明 DNS/IP 永远不变；远端身份仍由 SSH 主机密钥验证保证。
- 多跳**独立密码**、MFA/OTP、keyboard-interactive、部分认证成功后的二阶段认证、密码更新、私钥 passphrase 都不支持自动处理，绝不复用目标密码。跳板必须已能无交互认证。
- 如遇命令包装、复杂配置/规范化、非标准或本地化诊断、不同提示格式导致不能唯一识别，拒绝而不是猜测。配置可执行任意本地代码，恶意本地代码能伪造输出；这不在本工具可防御的信任边界内。

### 主机密钥与状态

所有主连接仍使用 `StrictHostKeyChecking=yes`，不会自动接受未知或变化的主机密钥。跳板主机也须预先独立核验；出现主机密钥交互提示会安全失败，不发送密码。不放宽用户配置中的密钥校验来促成连接。

SSH “运行中”只在主 SSH 明确输出匹配目标的 `Authenticated ... using publickey/password` 事件后设置，不再由存活计时触发。支持直连及 `via proxy` 成功诊断。它表示 SSH 认证成功，**不代表下游转发服务端到端可用**；转发失败仍可能随后退出。relay 的进程存活判断保持原有行为。

### 会话凭据与安全边界

- UI → daemon 使用原有同 UID、私有 Unix socket；daemon → bridge 使用匿名 stdin pipe。帧为四字节大端长度 + UTF-8 字节，零长度表示无密码的密钥优先尝试。非秘密目标绑定可放入 helper 参数；密码绝不进入 argv、环境变量、配置、命令预览、status、日志或外部文件。
- 不新增环境变量传递密码、指定 helper 或配置机制。正常继承系统 `SSH_AUTH_SOCK` 及配置的 agent 设置；bridge 子进程移除已有 `SSH_ASKPASS` / `SSH_ASKPASS_REQUIRE`，防止密码交互被重定向。helper 从 daemon 同目录加载，不从 PATH/环境选择。
- bridge 不转发原始 SSH/终端输出；daemon 只处理受限的目标身份、认证成功事件及固定退出原因。77 为认证失败，78 为身份/提示/输入不明确，79 才是经过上述证据确认的目标密码请求。网络失败按退避策略重试，不弹密码框。
- 每次 SSH 进程至多发送一次目标密码，且必须关闭终端回显。密码限 1–1023 UTF-8 字节，不含 ASCII 控制字符、换行、NUL 或 DEL。
- daemon 在当前隧道会话内存中保留密码及绑定身份，支持重连和 restart；stop/stopAll、删除、配置变更、认证失败、不支持提示、不可恢复配置错误或 daemon 退出清理。UI 关闭不会清理仍在运行的 daemon 会话；需要清除请停止隧道。
- daemon 重启不会恢复密码。密码回退隧道自动启动时先尝试密钥，只有明确请求才等待 UI；UI 未运行时保持等待，不进行密码猜测。
- C helper 禁用 core dump 并覆盖密码缓冲区；Swift 字符串、JSON、IPC 缓冲区可能存在短期副本。释放引用不保证物理内存擦除，不防御同 UID 恶意程序、调试器、root、系统交换/休眠或诊断采集。不会主动将凭据写盘，不承诺操作系统永不将内存落盘。

### 明确限制

- **支持仅 password 的服务器**：最终目标当前认证方法列表明确提供 password 而不提供 publickey 时，不要求不可能发生的公钥尝试，仍须身份、password 阶段与无回显目标提示全部匹配。若列表同时提供 publickey 和 password，则仍要求先选择过 publickey；缺失服务端方法列表不能当作“不支持 publickey”，会安全拒绝。部分认证成功的 MFA 与跳板歧义仍拒绝。
- OpenSSH 诊断不是稳定机器协议。对未知版本/格式安全拒绝，不保证任意 SSH 实现兼容；当前离线核对的是 macOS 系统 OpenSSH 9.9p2 的字符串格式。
- 复制命令不含凭据，也不是 helper IPC 协议；它仍是可独立运行的批处理 SSH 命令。
- 密码请求以普通 failed 状态附带非秘密 `passwordRequestID` 表示。UI 只对新请求弹一次，不会因一般连接失败弹框；重新启动可产生新的认证请求。
- 不需要 sshpass，无不安全 fallback。必须一起更新 app、daemon 和 bridge；缺失 bridge 时 SSH 启动失败。旧 daemon 不会提供新的请求 ID，需自行停止并运行新版。未自动停止用户当前 daemon。

## Mihomo TUN 启动顺序

Mihomo 只要求关联动态隧道配置存在，不要求隧道已运行。可先启动 TUN 再启动 SSH，也可反向；隧道未就绪时代理流量不可用。路由改变可能影响已有连接，不保证无中断，详见 README。

## 离线验证

```sh
swift test -j 2
python3 scripts/test-ssh-bridge.py
sh scripts/build-app.sh --adhoc-sign
```

Swift 测试覆盖命令配置保留、会话生命周期、只在明确请求时产生 UI challenge、过期请求拒绝、认证成功事件分片和存活不等于认证。Python 编译相同 bridge 源码，用本地假 SSH + 真实 PTY 验证认证方法列表、网络/host-key 错误、跳板提示、同名跳板、跳板 agent 后目标密码、目标绑定变化、提示分片、MFA/重复/回显拒绝、无秘密输出及进程回收。夹具逐字复现了在本机临时 sshd 上用真实 OpenSSH 9.9p2 抓取的 `-E` 日志与 PTY 字节（含 CRLF、提示前的 `\r`）；另用系统 ssh 连接本机关闭端口验证 `-E /dev/fd/1`。

这些测试不等于真实 SSH/ProxyJump 网络验收，也不测试实际系统 agent 或硬件设备。真实服务器、不同 OpenSSH 版本、复杂用户配置仍需单独验收；本次实现验证没有启动真实隧道。
