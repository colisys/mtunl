import Foundation
import Darwin

extension TunnelSupervisor {
    // MARK: Transitions (queue-confined)

    func startLocked(_ entry: Entry) {
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
        let command: ToolCommand
        do {
            command = try resolver(entry.config)
        } catch {
            // Configuration or a missing tool: retrying cannot help.
            entry.desired = false
            entry.state = .failed
            entry.message = error.localizedDescription
            return
        }
        let config = entry.config
        if config.kind.listensLocally, portInUse(config.bindAddress, config.listenPort) {
            return scheduleRetry(entry, reason: "本地端口 \(config.bindAddress):\(config.listenPort) 已被占用")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
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
            self?.queue.async { if let entry { Self.append(data, to: entry) } }
        }
        process.terminationHandler = { [weak self] finished in
            self?.queue.async {
                self?.handleExit(entry, generation: generation, status: finished.terminationStatus,
                                 signaled: finished.terminationReason == .uncaughtSignal)
            }
        }
        do {
            try process.run()
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
        entry.runningTimer = makeTimer(after: stableAfter) { [weak entry] in
            guard let entry, entry.generation == generation, entry.process != nil, !entry.stopping else { return }
            entry.state = .running
        }
    }

    private static func append(_ data: Data, to entry: Entry) {
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
        entry.errorPipe?.fileHandleForReading.readabilityHandler = nil
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
        if entry.relaunchNow {
            entry.relaunchNow = false
            entry.attempts = 0
            return launch(entry)
        }
        if uptime >= backoff.healthyUptime { entry.attempts = 0 }
        let reason = entry.log.last ?? (signaled ? "进程被信号终止（\(status)）" : "进程退出（代码 \(status)）")
        scheduleRetry(entry, reason: reason)
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
