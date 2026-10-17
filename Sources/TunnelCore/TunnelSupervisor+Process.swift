import Foundation
import Darwin

extension TunnelSupervisor {
    // MARK: Transitions (queue-confined)

    func startLocked(_ entry: Entry) {
        entry.passwordRequestID = nil
        entry.desired = true
        if entry.process != nil {
            if entry.stopping { entry.relaunchNow = true }
            return
        }
        cancelTimers(entry)
        entry.attempts = 0
        launch(entry)
    }

    func stopLocked(_ entry: Entry) {
        entry.desired = false
        entry.oneTimePassword = nil
        entry.passwordRequestID = nil
        entry.sshTarget = nil
        entry.relaunchNow = false
        entry.retryTimer?.cancel()
        entry.retryTimer = nil
        entry.retryAt = nil
        if entry.process != nil {
            terminate(entry)
        } else {
            entry.state = .stopped
            entry.message = nil
        }
    }

    func restartLocked(_ entry: Entry) {
        guard entry.process != nil else { return startLocked(entry) }
        entry.desired = true
        entry.relaunchNow = true
        terminate(entry)
    }

    private func terminate(_ entry: Entry) {
        guard let process = entry.process, !entry.stopping else { return }
        entry.stopping = true
        process.terminate()
        let generation = entry.generation
        queue.asyncAfter(deadline: .now() + 3) {
            if entry.generation == generation, entry.process === process, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func cancelTimers(_ entry: Entry) {
        entry.retryTimer?.cancel()
        entry.retryTimer = nil
        entry.runningTimer?.cancel()
        entry.runningTimer = nil
        entry.retryAt = nil
    }

    private func makeTimer(after delay: TimeInterval, _ fire: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler(handler: fire)
        timer.resume()
        return timer
    }

    // MARK: Launch / exit

    func launch(_ entry: Entry) {
        guard entry.desired, entry.process == nil else { return }
        
        let passwordFallback = entry.config.sshAuthMethod == .password || entry.oneTimePassword != nil
        let useBridge = entry.config.kind.usesSSH && (resolver == nil || entry.oneTimePassword != nil)
        entry.usesBridge = useBridge
        entry.eventBuffer.removeAll()
        let command: ToolCommand
        do {
            if let resolver {
                command = try resolver(entry.config)
            } else {
                try entry.config.validate()
                command = try CommandBuilder.command(for: entry.config, passwordFallback: passwordFallback)
            }
            if useBridge && !FileManager.default.isExecutableFile(atPath: bridgePath) {
                throw CommandBuilderError.toolNotFound("mtunl-ssh-bridge（请重新构建完整应用）")
            }
            if let password = entry.oneTimePassword {
                let bytes = Array(password.utf8)
                guard !bytes.isEmpty, bytes.count <= 1023, bytes.allSatisfy({ $0 >= 32 && $0 != 127 }) else {
                    throw CommandBuilderError.invalidSessionPassword
                }
                // Without an observed identity the bridge would refuse the password anyway; fail here instead.
                guard entry.sshTarget != nil else { throw CommandBuilderError.unknownSSHTarget }
            }
        } catch {
            // Configuration or a missing tool: retrying cannot help.
            entry.desired = false
            entry.oneTimePassword = nil
            entry.state = .failed
            entry.message = error.localizedDescription
            return
        }
        let config = entry.config
        if config.kind.listensLocally, portInUse(config.bindAddress, config.listenPort) {
            return scheduleRetry(entry, reason: "本地端口 \(config.bindAddress):\(config.listenPort) 已被占用")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: useBridge ? bridgePath : command.executable)
        var arguments = command.arguments
        if useBridge, entry.oneTimePassword != nil, let target = entry.sshTarget {
            // The bridge sends a password only when the identity ssh reports matches this exact target.
            arguments = ["--expect", target.user, target.host, target.port, "--"] + arguments
        }
        process.arguments = arguments
        let secretPipe = useBridge ? Pipe() : nil
        process.standardInput = secretPipe.map { $0 as Any } ?? FileHandle.nullDevice
        // Bounded frame fits before spawning: no post-spawn write/SIGPIPE race.
        if let secretPipe {
            let password = entry.oneTimePassword ?? ""
            var frame = Data()
            var size = UInt32(password.utf8.count).bigEndian
            withUnsafeBytes(of: &size) { frame.append(contentsOf: $0) }
            frame.append(contentsOf: password.utf8)
            secretPipe.fileHandleForWriting.write(frame)
            secretPipe.fileHandleForWriting.closeFile()
            frame.resetBytes(in: 0..<frame.count)
        }
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe

        entry.generation += 1
        let generation = entry.generation
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak entry] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                if let entry, entry.generation == generation { Self.append(data, to: entry) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            self?.queue.async {
                self?.handleExit(entry, generation: generation, status: finished.terminationStatus,
                                 signaled: finished.terminationReason == .uncaughtSignal)
            }
        }
        do {
            try process.run()
            secretPipe?.fileHandleForReading.closeFile()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return scheduleRetry(entry, reason: "无法启动：\(error.localizedDescription)")
        }
        entry.process = process
        entry.errorPipe = pipe
        entry.stopping = false
        entry.state = .starting
        entry.message = nil
        entry.startedAt = Date()
        entry.log.removeAll()
        if !useBridge {
            // Relay/test commands have no SSH authentication events.
            entry.runningTimer = makeTimer(after: stableAfter) { [weak entry] in
                guard let entry, entry.generation == generation, entry.process != nil, !entry.stopping else { return }
                entry.state = .running
            }
        }
    }

    static func append(_ data: Data, to entry: Entry) {
        if entry.usesBridge {
            entry.eventBuffer.append(data)
            while let newline = entry.eventBuffer.firstIndex(of: 10) {
                let line = String(decoding: entry.eventBuffer.prefix(upTo: newline), as: UTF8.self)
                entry.eventBuffer.removeSubrange(...newline)
                if line == "MTUNL_AUTHENTICATED", entry.process != nil, !entry.stopping, entry.desired {
                    entry.state = .running
                }
                if line.hasPrefix("MTUNL_TARGET "), let target = SSHTarget(event: line) {
                    entry.sshTarget = target
                }
                // Never expose unrecognized helper output, even if a child echoes a secret.
            }
            if entry.eventBuffer.count > 4096 { entry.eventBuffer.removeAll() }
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            entry.log.append(String(trimmed.prefix(300)))
        }
        if entry.log.count > 30 { entry.log.removeFirst(entry.log.count - 30) }
    }

    private func handleExit(_ entry: Entry, generation: Int, status: Int32, signaled: Bool) {
        guard entry.generation == generation else { return }
        let uptime = entry.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        cancelTimers(entry)
        Self.finishStderr(entry)
        entry.errorPipe = nil
        entry.process = nil
        entry.stopping = false

        if entry.pendingRemoval {
            entries[entry.config.id] = nil
            return
        }
        guard entry.desired else {
            entry.state = .stopped
            entry.message = nil
            return
        }
        if entry.usesBridge && status == 79 && !signaled && entry.oneTimePassword == nil && entry.sshTarget != nil {
            entry.desired = false
            entry.relaunchNow = false
            entry.state = .failed
            entry.passwordRequestID = UUID()
            entry.message = "密钥认证未通过，等待输入登录密码"
            return
        }
        // Check for authentication failure before honoring a pending restart.
        let isAuthFailure = status == 77 || status == 78 || status == 79 || entry.log.contains {
            $0.lowercased().contains("permission denied") || $0.lowercased().contains("authentication failed")
        }
        
        if isAuthFailure && (entry.usesBridge || entry.oneTimePassword != nil) {
            // Clear password on auth failure and stop retrying
            entry.oneTimePassword = nil
            entry.desired = false
            entry.state = .failed
            entry.message = status == 78 || status == 79 ? "认证提示不明确，已拒绝发送密码（请改用密钥或 agent）" : "认证失败，请重新输入密码"
            return
        }
        
        if entry.relaunchNow {
            entry.relaunchNow = false
            entry.attempts = 0
            return launch(entry)
        }
        if uptime >= backoff.healthyUptime { entry.attempts = 0 }
        let reason = entry.log.last ?? (signaled ? "进程被信号终止（\(status)）" : "进程退出（代码 \(status)）")
        scheduleRetry(entry, reason: reason)
    }

    // The bridge has exited, but its last stderr events may still be queued behind the readability
    // callback. Read them without blocking so a 79 always sees the target observed before its prompt.
    private static func finishStderr(_ entry: Entry) {
        guard let handle = entry.errorPipe?.fileHandleForReading else { return }
        handle.readabilityHandler = nil
        guard entry.usesBridge else { return }
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            append(Data(chunk.prefix(count)), to: entry)
        }
    }

    private func scheduleRetry(_ entry: Entry, reason: String) {
        entry.attempts += 1
        entry.restarts += 1
        let delay = backoff.delay(forAttempt: entry.attempts)
        entry.state = .waiting
        entry.message = reason
        entry.retryAt = Date().addingTimeInterval(delay)
        entry.retryTimer?.cancel()
        entry.retryTimer = makeTimer(after: delay) { [weak self, weak entry] in
            guard let self, let entry else { return }
            entry.retryTimer = nil
            entry.retryAt = nil
            self.launch(entry)
        }
    }
}
