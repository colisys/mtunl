# MTunl 新功能使用指南

## 1. 首次 SSH 连接自动信任主机密钥

### 功能说明
当你第一次连接到一个新的 SSH 主机时，MTunl 会自动接受并保存主机公钥，无需手动确认。

### 工作原理
- 使用 OpenSSH 的 `StrictHostKeyChecking=accept-new` 选项
- 首次连接时自动保存主机密钥到 `~/.ssh/known_hosts`
- 后续连接会验证主机密钥，防止中间人攻击
- 比 `StrictHostKeyChecking=no` 更安全

### 使用方法
无需任何配置，直接创建隧道并启动即可。如果首次连接失败，检查 SSH 错误日志（现在包含完整的 stderr 输出）。

---

## 2. 一次性密码认证

### 功能说明
支持使用密码进行 SSH 认证，密码仅在运行时使用，不会保存到配置文件中。

### 前置条件
需要安装 `sshpass` 工具：

```bash
brew install hudochenkov/sshpass/sshpass
```

### 使用方法

1. **创建或编辑隧道**
   - 在隧道编辑器中找到"密码（可选，一次性，不保存）"输入框
   - 输入 SSH 密码

2. **认证优先级**
   ```
   密码认证 > 私钥认证 > SSH Agent
   ```
   - 如果填写了密码，将使用密码认证（通过 sshpass）
   - 如果没有密码但指定了私钥，将使用私钥认证
   - 如果都没有，将尝试使用 SSH Agent

3. **安全性说明**
   - 密码存储在内存中，不写入磁盘
   - 配置文件（`~/.config/mtunl/tunnels.json`）不包含密码字段
   - 每次启动隧道需要重新输入密码
   - 停止隧道后密码会从内存清除

### 故障排查

**问题：启动隧道时提示找不到 sshpass**
```
解决：brew install hudochenkov/sshpass/sshpass
```

**问题：密码认证失败**
- 检查服务器是否允许密码登录（`/etc/ssh/sshd_config` 中 `PasswordAuthentication yes`）
- 确认密码正确
- 查看隧道日志中的 SSH 错误信息

---

## 3. Mihomo TUN 启动顺序灵活化

### 功能说明
Mihomo TUN 可以在 SSH 隧道建立之前启动，不再强制要求先启动 SSH。

### 工作原理
- Mihomo 启动时只需要**动态隧道配置存在**，不要求隧道正在运行
- TUN 接口可以提前建立，路由规则可以提前配置
- SSH 隧道连接建立后，流量会自动通过 SOCKS 代理转发
- 即使 TUN 先启动，也不会中断后续的 SSH 连接

### 推荐使用顺序

#### 方案 A：先启动 TUN（推荐）
```
1. 配置 Mihomo，选择动态隧道
2. 启动 Mihomo TUN
3. 启动 SSH 动态隧道（-D）
4. 流量开始通过隧道转发
```

**优势**：
- TUN 接口和路由规则提前就绪
- SSH 连接不会因为 TUN 启动而中断
- 更稳定的启动流程

#### 方案 B：先启动 SSH
```
1. 启动 SSH 动态隧道（-D）
2. 配置并启动 Mihomo TUN
3. 流量开始通过隧道转发
```

**注意**：
- Mihomo 启动 TUN 时可能会短暂影响网络
- 如果 SSH 连接中断，需要重新连接

### 验证

检查 Mihomo 状态：
```bash
# 查看 TUN 是否启用
# 在 MTunl 界面中查看状态：运行中 | TUN: enabled

# 验证路由
netstat -rn | grep utun
```

---

## 技术细节

### SSH 命令变化

#### 无密码认证（使用密钥或 Agent）
```bash
/usr/bin/ssh -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o ConnectTimeout=10 \
  -o ControlMaster=no \
  -o ControlPath=none \
  -o StrictHostKeyChecking=accept-new \
  -o BatchMode=yes \
  -D 127.0.0.1:8080 \
  -- user@host
```

#### 使用密码认证
```bash
/opt/homebrew/bin/sshpass -p 'your-password' \
  /usr/bin/ssh -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o ConnectTimeout=10 \
  -o ControlMaster=no \
  -o ControlPath=none \
  -o StrictHostKeyChecking=accept-new \
  -D 127.0.0.1:8080 \
  -- user@host
```

**注意变化**：
- 密码模式下**没有** `-o BatchMode=yes`，允许交互式认证
- 使用 `sshpass -p` 传递密码
- `StrictHostKeyChecking=accept-new` 替代了旧的 `BatchMode` 导致的首次连接失败

### 主机密钥管理

首次连接后，主机密钥保存在 `~/.ssh/known_hosts`：
```
example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...
```

删除已知主机密钥（如果需要重新信任）：
```bash
ssh-keygen -R example.com
```

---

## 常见问题

### Q: 为什么密码不保存到配置文件？
A: 安全考虑。密码认证应该是临时的、一次性的。对于长期使用，建议配置 SSH 密钥对。

### Q: 如何设置 SSH 密钥登录？
A: 
```bash
# 生成密钥对
ssh-keygen -t ed25519 -C "your_email@example.com"

# 复制公钥到服务器
ssh-copy-id user@host

# 在 MTunl 中指定私钥路径（如 ~/.ssh/id_ed25519）
```

### Q: Mihomo TUN 启动会中断现有 SSH 连接吗？
A: 实验证明不会。TUN 启动时会修改路由表，但已建立的 TCP 连接（如 SSH）不会中断。

### Q: 如何调试 SSH 连接失败？
A: 
1. 查看 MTunl 隧道日志（现在包含完整 stderr 输出）
2. 手动测试连接：
   ```bash
   ssh -vvv user@host
   ```
3. 检查服务器 `/var/log/auth.log` 或 `/var/log/secure`

---

## 更新历史

- **2026-10-17**
  - 添加首次连接自动信任功能
  - 添加一次性密码认证支持
  - 确认 Mihomo 可以先于 SSH 启动
