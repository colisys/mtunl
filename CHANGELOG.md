# MTunl Changelog

## [Unreleased]

### Security
- 移除 sshpass 依赖及明文密码 argv 路径，没有不安全 fallback。
- 新增编译的 `mtunl-ssh-bridge`：通过匿名 stdin 管道接收密码，驱动系统 SSH 的 PTY；密码不进入命令、环境变量、外部文件或日志。
- OpenSSH 优先尝试 publickey（agent、默认/指定密钥），其次原生 password；不以 identity 路径是否存在判断 agent 可用性。
- 密码回退保留 SSH config / ProxyJump / ProxyCommand，信任用户配置，不把认证识别宣称为 ProxyCommand 安全保证。
- 优先运行服务端允许的密钥认证，仅最终目标认证方法/上下文/提示明确时请求 UI 密码；网络及主机密钥错误不弹框。跳板 agent → 目标密码可用，跳板密码/MFA/歧义提示拒绝。
- 目标身份与密码提示均取自实际 SSH 的匿名 `-v -E /dev/fd/1` 日志，不再使用 `ssh -G`；缓存密码绑定最终 user/hostname/port，不一致时拒绝发送。
- 所有 SSH 连接改为 `StrictHostKeyChecking=yes`，未知主机需独立核验，不再自动信任首次密钥。
- `startSession` 携带一次性非秘密请求 ID，拒绝未经请求或过期的密码提交；旧 daemon 不提供请求 ID，需手动更新。

### Fixed
- 修复所有主机密码启动均被拒绝（78）：OpenSSH 的 `-E` 日志以 CRLF 结尾，bridge 将 `\r` 当作内容导致身份行不匹配；同时 PTY 在提示前会输出单独的 `\r`。均已按真实输出处理。
- 修复仅 password 的服务器被拒绝：服务端明确提供 password 而不提供 publickey 时允许请求目标密码；方法列表缺失、目标/跳板歧义、回显及 MFA 拒绝不变。
- SSH 认证成功由明确诊断事件确认，不再将进程存活计时当认证成功；UI 启动不再提前弹密码框。
- 会话密码在“运行中”及网络重连期间保留；停止、删除、配置变化、认证失败或不支持交互时清除。
- 删除等待重试的隧道时取消计时器并清理凭据。
- 从配置模型移除运行时密码字段，status 和命令预览不含凭据。

### Added
- 离线 PTY 集成测试及会话生命周期回归测试，无需外部 sshpass 或真实 SSH 服务器。
- 完整的构建/打包/签名支持及认证限制说明，见 [FEATURES.md](FEATURES.md)。

### Other
- Mihomo 可以先于关联 SSH 隧道启动；修改路由仍可能影响连接，不保证无中断。
