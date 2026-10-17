# MTunl Changelog

## [Unreleased]

### Added
- **首次连接公钥自动确认**：SSH 隧道首次连接未知主机时自动接受公钥，无需手动确认（使用 `StrictHostKeyChecking=accept-new`）
- **一次性密码登录支持**：在隧道编辑器中添加密码输入框，支持使用密码认证（需要安装 `sshpass`）
  - 密码仅在运行时使用，不会保存到配置文件
  - 优先级：密码认证 > 私钥认证 > SSH Agent
  - 安装方式：`brew install hudochenkov/sshpass/sshpass`

### Changed
- SSH 连接错误信息现在包含 stderr 输出，便于调试连接问题
- 移除 `BatchMode=yes`（密码认证模式下），允许交互式认证
- **Mihomo 启动顺序灵活化**：可以先启动 Mihomo TUN，再启动 SSH 隧道（之前误以为必须先启动 SSH）
  - Mihomo 只需要关联的动态隧道配置存在，不要求隧道已经运行
  - TUN 可以在 SSH 连接建立前启动，不会影响网络路由

### Technical Details

#### 密码认证实现
使用 `sshpass` 工具传递密码给 SSH：
```bash
sshpass -p 'password' /usr/bin/ssh [options]
```

如果未安装 `sshpass`，密码认证将失败并提示安装。

#### 公钥确认策略
- `StrictHostKeyChecking=accept-new`：首次连接自动接受新主机密钥，后续连接验证已知主机
- 主机密钥保存在 `~/.ssh/known_hosts`
- 这比旧的 `StrictHostKeyChecking=no` 更安全，避免 MITM 攻击

## [Previous Versions]
... (historical changes)
