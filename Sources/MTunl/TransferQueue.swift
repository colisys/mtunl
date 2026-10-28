import Foundation
import TunnelCore

/// Background transfer queue: runs uploads/downloads with limited
/// concurrency so the UI stays responsive, and supports cancelling
/// queued or in-flight items.
@MainActor
final class TransferQueue: ObservableObject {
    static let maxConcurrent = 2

    enum Direction {
        case upload, download
    }

    enum State: Equatable {
        case queued, running, paused, completed, failed, cancelled
    }

    final class TransferItem: Identifiable, ObservableObject {
        let id = UUID()
        let direction: Direction
        let name: String
        let size: Int64
        let localPath: String
        let remotePath: String
        let config: TunnelConfig

        @Published var state: State = .queued
        @Published var error: String?
        @Published var chunkStates: [Int: ChunkState] = [:]

        var task: Task<Void, Never>?
        var process: Process?
        /// Processes of a chunked transfer; cancel terminates all of them.
        var chunkProcesses: [Process] = []

        init(direction: Direction, name: String, size: Int64,
             localPath: String, remotePath: String, config: TunnelConfig) {
            self.direction = direction
            self.name = name
            self.size = size
            self.localPath = localPath
            self.remotePath = remotePath
            self.config = config
        }

        /// True when this file is large enough to be worth splitting.
        var isChunked: Bool { size > SFTPClient.chunkedTransferThreshold }
    }

    @Published private(set) var items: [TransferItem] = []
    private var runningCount = 0

    var activeCount: Int {
        items.filter { $0.state == .queued || $0.state == .running }.count
    }

    func enqueueUploads(_ files: [LocalFile], to remotePath: String, config: TunnelConfig) {
        for file in files {
            let remoteTarget = remotePath.hasSuffix("/")
                ? remotePath + file.name
                : remotePath + "/" + file.name
            let item = TransferItem(
                direction: .upload, name: file.name, size: file.size,
                localPath: file.path, remotePath: remoteTarget, config: config
            )
            items.append(item)
            schedule()
        }
    }

    func enqueueDownloads(_ files: [RemoteFile], to localPath: String, config: TunnelConfig) {
        for file in files {
            let localTarget = (localPath as NSString).appendingPathComponent(file.name)
            let item = TransferItem(
                direction: .download, name: file.name, size: file.size,
                localPath: localTarget, remotePath: file.path, config: config
            )
            items.append(item)
            schedule()
        }
    }

    func pause(_ item: TransferItem) {
        guard item.state == .running, item.isChunked else { return }
        item.state = .paused
        item.task?.cancel()
        if let process = item.process, process.isRunning { process.terminate() }
        for process in item.chunkProcesses where process.isRunning { process.terminate() }
    }

    func resume(_ item: TransferItem) {
        guard item.state == .paused else { return }
        item.state = .queued
        schedule()
    }

    /// Requeue a failed/cancelled chunked transfer. The transfer implementation
    /// verifies existing parts and skips completed ones, so this retries only
    /// failed or missing chunks rather than restarting the whole file.
    func retry(_ item: TransferItem) {
        guard item.isChunked,
              item.state == .failed || item.state == .cancelled else { return }
        item.error = nil
        item.state = .queued
        schedule()
    }

    func cancel(_ item: TransferItem) {
        guard item.state == .queued || item.state == .running else { return }
        item.state = .cancelled
        item.task?.cancel()
        // Kill the in-flight sftp process(es). Chunked transfers own several.
        if let process = item.process, process.isRunning {
            process.terminate()
        }
        for process in item.chunkProcesses where process.isRunning {
            process.terminate()
        }
    }

    func cancelAll() {
        for item in items where item.state == .queued || item.state == .running {
            cancel(item)
        }
    }

    func clearFinished() {
        items.removeAll { $0.state == .completed || $0.state == .failed || $0.state == .cancelled }
    }

    private func schedule() {
        while runningCount < Self.maxConcurrent,
              let item = items.first(where: { $0.state == .queued }) {
            runningCount += 1
            item.state = .running
            item.task = Task { await run(item) }
        }
    }

    private func run(_ item: TransferItem) async {
        do {
            switch item.direction {
            case .upload:
                if item.isChunked {
                    try await SFTPClient.uploadChunked(
                        localPath: item.localPath, remotePath: item.remotePath,
                        config: item.config, size: item.size,
                        onProcessStart: { [weak item] process in
                            Task { @MainActor in item?.chunkProcesses.append(process) }
                        },
                        onStateChange: { [weak item] states in
                            Task { @MainActor in item?.chunkStates = states }
                        }
                    )
                } else {
                    try await SFTPClient.upload(
                        localPath: item.localPath, remotePath: item.remotePath,
                        config: item.config
                    ) { [weak item] process in
                        item?.process = process
                    }
                }
            case .download:
                if item.isChunked {
                    try await SFTPClient.downloadChunked(
                        remotePath: item.remotePath, localPath: item.localPath,
                        config: item.config, size: item.size,
                        onProcessStart: { [weak item] process in
                            Task { @MainActor in item?.chunkProcesses.append(process) }
                        },
                        onStateChange: { [weak item] states in
                            Task { @MainActor in item?.chunkStates = states }
                        }
                    )
                } else {
                    try await SFTPClient.download(
                        remotePath: item.remotePath, localPath: item.localPath,
                        config: item.config
                    ) { [weak item] process in
                        item?.process = process
                    }
                }
            }
            item.state = .completed
        } catch is CancellationError {
            if item.state != .paused { item.state = .cancelled }
        } catch {
            if item.state == .paused {
                // Pause keeps verified parts for resume.
            } else if Task.isCancelled {
                item.state = .cancelled
            } else {
                item.state = .failed
                item.error = error.localizedDescription
            }
        }
        item.process = nil
        item.chunkProcesses = []
        runningCount = max(0, runningCount - 1)
        schedule()
    }
}
