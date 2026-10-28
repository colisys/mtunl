# SSH 行为与安全说明

## SFTP 文件管理

MTunl 提供基于 SSH 多路复用连接的 SFTP 文件管理功能（菜单栏 → 隧道 → 更多 → SFTP 文件管理）。

### 核心能力

- **文件上传**：支持多选文件上传到远程目录
- **文件下载**：支持单个或批量下载到本地目录
- **复制 / 剪切 / 粘贴**：在远程服务器上实现文件操作，复用 SSH 连接无需二次认证
- **批量操作**：可同时对多个文件执行删除、复制、剪切等操作
- **文件信息**：显示权限（rwx）、所有者、所属组、大小、修改时间
- **压缩 / 解压**：使用远程命令，支持多种格式
  - **解压支持**: `.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz2`, `.tbz`, `.tar.xz`, `.txz`, `.tar`, `.zip`, `.rar`, `.7z`, `.gz`, `.bz2`, `.xz`
  - **压缩支持**: `.tar.gz`（默认）
  - **远程工具依赖**:
    - tar 格式: `tar`（通常预装）
    - zip: `unzip`
    - rar: `unrar` 或 `unar`/`7z`
    - 7z: `7z`（需要 `p7zip` 包）
    - gz/bz2/xz: `gunzip`/`bunzip2`/`unxz`（通常预装）

### 工作原理

- 文件列表、权限查询等操作通过 SSH 执行远程命令（`ls -l`, `stat` 等）获取信息
- 文件上传、下载等传输操作使用 `/usr/bin/sftp` 的 batch 模式（`-b`）进行
- 压缩 / 解压操作通过 SSH 执行远程 `tar -czf` / `tar -xzf` 命令
- 所有操作复用隧道的 SSH ControlMaster 连接，共享已建立的认证会话
- 隧道未运行时，需要独立认证（密钥或 agent），不支持交互式密码
- 远程 shell 命令参数使用单引号转义；SFTP batch 参数使用双引号和反斜杠转义

### 安全考虑

- 不存储或缓存任何文件内容
- 路径参数严格转义，避免命令注入
- 权限继承远程服务器的 POSIX 权限模型

## SSH 与主机密钥

MTunl 只调用 macOS 系统 `/usr/bin/ssh`，用 PTY 处理交互、管理 SSH 端口转发；不实现 SSH 协议。保留 `~/.ssh/config`、别名、agent、ProxyJump 和 ProxyCommand。SSH 配置可能执行本地命令，因此只使用你信任的配置。

首次连接未知主机时，MTunl 显示系统 SSH 提供的 SHA256 指纹。核对管理员提供的指纹后，选择“信任并连接”；SSH 随后按系统行为记录主机密钥。取消会停止连接。已变化的指纹不会弹出信任选项，也不会自动覆盖 `known_hosts`，而是直接失败；请先独立核实服务器身份，再按需处理旧记录。

## 认证

- 首先由系统 SSH 尝试配置的密钥和 agent。可选的密码回退只在 SSH 明确进入最终目标的 password 认证、并出现匹配的无回显密码提示时请求输入；不探测或模拟认证能力。
- 密码经本地控制 socket 和匿名 stdin 管道传递，不进入 argv、环境变量、配置、日志或命令预览。只在 daemon 内存中保留至停止、删除、配置变化、认证失败或 daemon 退出。
- 加密私钥请先用 `ssh-add` 解锁。MFA、keyboard-interactive、跳板机密码和私钥 passphrase 不由 MTunl 自动处理；不明确的提示会安全失败。
- 认证状态以系统 SSH 的成功事件为准。网络错误按退避策略重试；主机指纹变化和认证错误不会反复重试。

### 钥匙串自动认证

- 密码回退对话框中勾选「保存到钥匙串，以后自动认证」即可把密码存入 macOS 钥匙串。
- 条目类型为通用密码（generic password），服务名 `MTunl SSH`，账户名 `user@host`；可在「钥匙串访问」中查看或手动删除。
- 隧道侧：桥接进程报告密码请求时，监督器先查钥匙串，命中则通过既有的匿名 stdin 密管道自动重认证，不再弹窗。
- SFTP 侧：通过 `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` 把密码交给系统 `ssh`/`sftp`，辅助脚本从继承的环境变量读取，密码不进 argv、不落盘。
- 钥匙串是通用机制，不限于 SFTP：隧道与 SFTP 共用同一个条目。
- 密码不进入 argv、环境变量（隧道侧）、配置或日志；SFTP 的 askpass 路径会经环境变量 `MTUNL_PASS` 传给子进程，辅助脚本位于临时目录且权限为 `0700`，用完即删。

## 验证

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -j 2
python3 scripts/test-ssh-bridge.py
sh scripts/build-app.sh --adhoc-sign
```

测试使用假 SSH 和真实 PTY；此外，主机密钥首次确认行为已用临时 `known_hosts` 对本机 OpenSSH / sshd 验证。不会修改用户现有的 `~/.ssh/known_hosts`。
