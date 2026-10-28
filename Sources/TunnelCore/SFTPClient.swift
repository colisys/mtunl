import CryptoKit
import Foundation

/// SFTP operation types
public enum SFTPOperation: String, Codable, Sendable {
    case list       // ls -la
    case download   // get
    case upload     // put
    case delete     // rm
    case mkdir      // mkdir
    case rmdir      // rmdir
    case rename     // rename
    case chmod      // chmod
    case stat       // stat
    case compress   // tar compress on remote
    case decompress // tar extract on remote
}

/// Remote file information
public struct RemoteFile: Identifiable, Codable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var permissions: String
    public var owner: String
    public var group: String
    public var modifiedTime: String
    
    public init(path: String, name: String, isDirectory: Bool, size: Int64,
                permissions: String, owner: String, group: String, modifiedTime: String) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.modifiedTime = modifiedTime
    }
}

/// SFTP batch operation item
public struct SFTPBatchItem: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var operation: SFTPOperation
    public var sourcePath: String
    public var destinationPath: String?
    public var completed: Bool = false
    public var error: String?
    
    public init(operation: SFTPOperation, sourcePath: String, destinationPath: String? = nil) {
        self.operation = operation
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }
}

public enum ChunkState: Equatable, Sendable {
    case pending
    case running(Double)
    case retrying(Int)
    case done
    case failed
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public enum SFTPError: LocalizedError, Equatable {
    case connectionFailed(String)
    case commandFailed(String)
    case invalidPath(String)
    case permissionDenied(String)
    case fileNotFound(String)
    case operationCancelled
    case unknown(String)
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "SFTP 连接失败: \(msg)"
        case .commandFailed(let msg): return "命令执行失败: \(msg)"
        case .invalidPath(let path): return "无效路径: \(path)"
        case .permissionDenied(let msg): return "权限不足: \(msg)"
        case .fileNotFound(let path): return "文件未找到: \(path)"
        case .operationCancelled: return "操作已取消"
        case .unknown(let msg): return "未知错误: \(msg)"
        }
    }
}

/// SFTP client that wraps the system `sftp` command and can multiplex over
/// an existing SSH control socket from a running tunnel.
public enum SFTPClient {
    /// Pipelining flags for file transfers. `-R` allows 64 outstanding requests
    /// so a multiplexed channel keeps data in flight instead of waiting for
    /// each reply. `-B` must stay well under the SSH channel message limit:
    /// over a ControlMaster socket a 1 MB buffer fails with "Outbound message
    /// too long", so use 64 KB and rely on request depth for throughput.
    /// Only meaningful for `get`/`put`, not for `rm` and other short operations.
    private static let transferFlags: [String] = ["-B", "65536", "-R", "64"]

    /// Build SFTP connection arguments, multiplexing over the tunnel's existing
    /// SSH connection. The master has already authenticated, so no credentials
    /// are needed here and none are passed to child processes.
    public static func sftpCommand(for config: TunnelConfig, transferOptions: [String] = []) throws -> [String] {
        let socketPath = CommandBuilder.sshControlPath(for: config)
        var args = transferOptions + [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(socketPath)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        
        if let port = config.sshPort {
            args += ["-P", String(port)]
        }
        if let identity = config.identityFile, !identity.isEmpty {
            args += ["-i", identity]
        }
        if let jump = config.jumpHost, !jump.isEmpty {
            args += ["-J", jump]
        }
        
        args.append(config.destination)
        return args
    }
    
    /// Build SSH command arguments for running remote commands, multiplexing
    /// over the tunnel's ControlMaster.
    static func sshCommand(for config: TunnelConfig) throws -> [String] {
        let socketPath = CommandBuilder.sshControlPath(for: config)
        var args = [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(socketPath)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        
        if let port = config.sshPort {
            args += ["-p", String(port)]  // Note: -p for ssh, -P for sftp
        }
        if let identity = config.identityFile, !identity.isEmpty {
            args += ["-i", identity]
        }
        if let jump = config.jumpHost, !jump.isEmpty {
            args += ["-J", jump]
        }
        
        args += ["--", config.destination]
        return args
    }
    
    /// List remote directory contents
    /// List files in a directory
    public static func listDirectory(at remotePath: String, config: TunnelConfig) async throws -> [RemoteFile] {
        // Use ls -la for detailed listing
        let command = "ls -la \(Self.escapeShellArg(remotePath))"
        let args = try sshCommand(for: config) + [command]
        
        let (output, status) = try await runSSHCommand(args: args, config: config)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("ls 命令失败: \(output)")
        }
        
        return try parseDirectoryListing(output, basePath: remotePath)
    }
    
    /// Get file/directory statistics
    public static func stat(remotePath: String, config: TunnelConfig) async throws -> RemoteFile {
        // Use stat command for detailed info (try Linux format, then BSD/macOS format)
        let command = "stat -c '%n|%s|%a|%U|%G|%y|%F' \(Self.escapeShellArg(remotePath)) 2>/dev/null || stat -f '%N|%z|%p|%Su|%Sg|%Sm|%HT' \(Self.escapeShellArg(remotePath))"
        let args = try sshCommand(for: config) + [command]
        
        let (output, status) = try await runSSHCommand(args: args, config: config)
        
        guard status == 0 else {
            throw SFTPError.fileNotFound(remotePath)
        }
        
        return try parseStatOutput(output, path: remotePath)
    }
    
    /// Download a file from remote to local, multiplexing over the tunnel's
    /// ControlMaster. `-R`/`-B` raise the in-flight request depth and buffer
    /// size: a single multiplexed channel otherwise serializes one read per
    /// round trip, which collapses throughput to RTT-bound speeds.
    public static func download(remotePath: String, localPath: String, config: TunnelConfig, onProcessStart: ((Process) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let sftpArgs = try sftpCommand(for: config, transferOptions: transferFlags)
        let batchCommands = "get -r \(Self.escapeSFTPArg(remotePath)) \(Self.escapeSFTPArg(localPath))\nbye\n"
        
        let (output, status) = try await runSFTPBatch(args: sftpArgs, batchCommands: batchCommands, config: config, onProcessStart: onProcessStart)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("下载失败: \(output)")
        }
    }
    
    /// Upload a file from local to remote, multiplexing over the tunnel's ControlMaster.
    public static func upload(localPath: String, remotePath: String, config: TunnelConfig, onProcessStart: ((Process) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let sftpArgs = try sftpCommand(for: config, transferOptions: transferFlags)
        let batchCommands = "put -r \(Self.escapeSFTPArg(localPath)) \(Self.escapeSFTPArg(remotePath))\nbye\n"
        
        let (output, status) = try await runSFTPBatch(args: sftpArgs, batchCommands: batchCommands, config: config, onProcessStart: onProcessStart)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("上传失败: \(output)")
        }
    }

    // MARK: - Chunked parallel transfer

    /// Files at or below this size take the single-stream path; splitting
    /// overhead (extra sftp processes, remote concat) is not worth it.
    public static let chunkedTransferThreshold: Int64 = 32 * 1024 * 1024
    /// Size of one parallel chunk: 16 MB keeps the part count reasonable
    /// while giving the scheduler enough pieces to balance across workers.
    public static let chunkSize: Int64 = 16 * 1024 * 1024
    /// Parallel sftp workers per transfer.
    public static let chunkWorkers = 8
    public static let chunkMaxAttempts = 3

    /// Byte ranges covering `size`: every chunk except the last is
    /// `chunkSize` long. Pure for unit testing.
    public static func chunkRanges(size: Int64, chunkSize: Int64 = SFTPClient.chunkSize) -> [(offset: Int64, length: Int64)] {
        guard size > 0 else { return [] }
        var ranges: [(offset: Int64, length: Int64)] = []
        var offset: Int64 = 0
        while offset < size {
            let length = min(chunkSize, size - offset)
            ranges.append((offset, length))
            offset += length
        }
        return ranges
    }

    /// Remote temporary part path for chunk `index` of `remotePath`.
    static func partPath(for remotePath: String, index: Int) -> String {
        "\(remotePath).mtunl-part-\(String(format: "%04d", index))"
    }

    /// Uploads `localPath` to `remotePath` in parallel chunks over independent
    /// multiplexed channels, then concatenates the parts on the remote shell.
    ///
    /// - Each part is verified with md5 after upload; mismatch counts as failure.
    /// - A failed part is retried up to `maxAttempts`, dropping the remote part
    ///   before each retry so a half-written file is never reused.
    /// - Verified parts from an earlier interrupted run are detected by md5 and
    ///   skipped, so pause/resume only transfers the missing chunks.
    /// - On cancellation the remote parts are left in place for the next run;
    ///   real errors clean them up.
    /// - `onStateChange` reports the per-chunk state for the UI heatmap.
    public static func uploadChunked(
        localPath: String, remotePath: String, config: TunnelConfig,
        size: Int64, workers: Int = SFTPClient.chunkWorkers,
        maxAttempts: Int = SFTPClient.chunkMaxAttempts,
        isCancelled: @escaping () -> Bool = { Task.isCancelled },
        onProcessStart: @escaping (Process) -> Void = { _ in },
        onStateChange: @escaping ([Int: ChunkState]) -> Void = { _ in }
    ) async throws {
        let ranges = chunkRanges(size: size)
        let parts = ranges.indices.map { partPath(for: remotePath, index: $0) }
        let lock = NSLock()
        var states: [Int: ChunkState] = Dictionary(uniqueKeysWithValues: ranges.indices.map { ($0, .pending) })

        func report(_ index: Int, _ state: ChunkState) {
            lock.lock()
            states[index] = state
            let snapshot = states
            lock.unlock()
            onStateChange(snapshot)
        }

        do {
            try await runParallel(workers: workers, jobs: ranges.indices) { index in
                let slice = ranges[index]

                // Resume: a remote part from an interrupted run is reused
                // only when its md5 matches the local slice exactly.
                if let sliceMD5 = localSliceMD5(source: localPath, offset: slice.offset, length: slice.length),
                   let existingMD5 = try? await SFTPClient.remoteMD5(parts[index], config: config),
                   existingMD5 == sliceMD5 {
                    report(index, .done)
                    return
                }

                // Slice once locally; every retry reuses the same bytes.
                let temp = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("mtunl-chunk-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: temp) }
                try extractLocalSlice(
                    source: localPath, destination: temp.path,
                    offset: slice.offset, length: slice.length
                )
                let expectedMD5 = md5Hex(of: temp)

                var lastError: Error?
                for attempt in 1...max(maxAttempts, 1) {
                    try Task.checkCancellation()
                    if isCancelled() { throw CancellationError() }
                    report(index, attempt == 1 ? .running(0) : .retrying(attempt))
                    do {
                        let sftpArgs = try sftpCommand(for: config, transferOptions: transferFlags)
                        let batch = "put \(Self.escapeSFTPArg(temp.path)) \(Self.escapeSFTPArg(parts[index]))\nbye\n"
                        let (output, status) = try await runSFTPBatch(args: sftpArgs, batchCommands: batch, config: config, onProcessStart: onProcessStart, onProgress: { fraction in
                            report(index, .running(fraction))
                        })
                        guard status == 0 else {
                            throw SFTPError.commandFailed("分块上传失败: \(output)")
                        }
                        // Verify the part actually matches what we sent.
                        let actualMD5 = try await SFTPClient.remoteMD5(parts[index], config: config)
                        guard actualMD5 == expectedMD5 else {
                            throw SFTPError.commandFailed("分块 \(index) md5 不匹配")
                        }
                        report(index, .done)
                        return
                    } catch is CancellationError {
                        // Drop only the part that was in flight; verified parts remain.
                        _ = try? await runSSHCommand(
                            args: sshCommand(for: config) + ["rm -f \(Self.escapeShellArg(parts[index]))"],
                            config: config)
                        throw CancellationError()
                    } catch {
                        lastError = error
                        // Drop the possibly corrupt part before retrying.
                        _ = try? await runSSHCommand(
                            args: sshCommand(for: config) + ["rm -f \(Self.escapeShellArg(parts[index]))"],
                            config: config)
                        if attempt < maxAttempts {
                            try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                        }
                    }
                }
                report(index, .failed)
                throw lastError ?? SFTPError.commandFailed("分块 \(index) 上传失败")
            }

            // Assemble and verify the whole file on the remote side.
            let quoted = parts.map { Self.escapeShellArg($0) }.joined(separator: " ")
            let command = "cat \(quoted) > \(Self.escapeShellArg(remotePath))"
            let (output, status) = try await runSSHCommand(args: sshCommand(for: config) + [command], config: config)
            guard status == 0 else {
                throw SFTPError.commandFailed("远端拼接失败: \(output)")
            }
            let localMD5 = md5Hex(of: URL(fileURLWithPath: localPath))
            let remoteMD5 = try await remoteMD5(remotePath, config: config)
            guard localMD5 == remoteMD5 else {
                throw SFTPError.commandFailed("整文件 md5 校验失败")
            }
            _ = try? await runSSHCommand(args: sshCommand(for: config) + ["rm -f \(quoted)"], config: config)
        } catch is CancellationError {
            // Pause/cancel: keep verified remote parts so the next run resumes.
            throw CancellationError()
        } catch {
            // Keep remote parts on failure too: a red chunk can be retried
            // without retransferring green, verified chunks.
            throw error
        }
    }

    /// Downloads `remotePath` in parallel chunks: each worker extracts its
    /// byte range into a remote temp part with dd, pulls it back, and the
    /// local slices are concatenated into `localPath`.
    ///
    /// Mirrors `uploadChunked`: per-part md5 verification, retries with part
    /// drop, resume from verified local parts, parts kept on cancellation.
    /// Local parts are deterministic `.mtunl-part-NNNN` files next to the
    /// destination so an interrupted run can pick up where it stopped.
    public static func downloadChunked(
        remotePath: String, localPath: String, config: TunnelConfig,
        size: Int64, workers: Int = SFTPClient.chunkWorkers,
        maxAttempts: Int = SFTPClient.chunkMaxAttempts,
        isCancelled: @escaping () -> Bool = { Task.isCancelled },
        onProcessStart: @escaping (Process) -> Void = { _ in },
        onStateChange: @escaping ([Int: ChunkState]) -> Void = { _ in }
    ) async throws {
        let ranges = chunkRanges(size: size)
        let parts = ranges.indices.map { partPath(for: remotePath, index: $0) }
        let localParts = ranges.indices.map { localPartPath(for: localPath, index: $0) }
        let lock = NSLock()
        var states: [Int: ChunkState] = Dictionary(uniqueKeysWithValues: ranges.indices.map { ($0, .pending) })

        func report(_ index: Int, _ state: ChunkState) {
            lock.lock()
            states[index] = state
            let snapshot = states
            lock.unlock()
            onStateChange(snapshot)
        }

        do {
            try await runParallel(workers: workers, jobs: ranges.indices) { index in
                let slice = ranges[index]
                let localPart = localParts[index]

                // Resume: a local part left over from an interrupted run is
                // reused only when its md5 matches what the remote slice has.
                if FileManager.default.fileExists(atPath: localPart),
                   let partMD5 = md5HexIfComplete(localPart, length: slice.length),
                   let existingMD5 = try? await SFTPClient.remoteMD5(parts[index], config: config),
                   existingMD5 == partMD5 {
                    report(index, .done)
                    return
                }

                var lastError: Error?
                for attempt in 1...max(maxAttempts, 1) {
                    try Task.checkCancellation()
                    if isCancelled() { throw CancellationError() }
                    report(index, attempt == 1 ? .running(0) : .retrying(attempt))
                    do {
                        // GNU dd has iflag=skip_bytes,count_bytes; busybox/BSD
                        // dd do not, so fall back to a tail+head pipe there.
                        let gnu = "dd if=\(Self.escapeShellArg(remotePath)) of=\(Self.escapeShellArg(parts[index])) bs=1M iflag=skip_bytes,count_bytes skip=\(slice.offset) count=\(slice.length) 2>/dev/null"
                        let portable = "tail -c +\(slice.offset + 1) \(Self.escapeShellArg(remotePath)) | head -c \(slice.length) > \(Self.escapeShellArg(parts[index]))"
                        let command = "\(gnu) 2>/dev/null || \(portable)"
                        let (output, status) = try await runSSHCommand(args: sshCommand(for: config) + [command], config: config)
                        guard status == 0 else {
                            throw SFTPError.commandFailed("远端分块失败: \(output)")
                        }

                        let sftpArgs = try sftpCommand(for: config, transferOptions: transferFlags)
                        let batch = "get \(Self.escapeSFTPArg(parts[index])) \(Self.escapeSFTPArg(localPart))\nbye\n"
                        let (sftpOutput, sftpStatus) = try await runSFTPBatch(args: sftpArgs, batchCommands: batch, config: config, onProcessStart: onProcessStart, onProgress: { fraction in
                            report(index, .running(fraction))
                        })
                        guard sftpStatus == 0 else {
                            throw SFTPError.commandFailed("分块下载失败: \(sftpOutput)")
                        }
                        // Verify the pulled part byte-for-byte against the
                        // remote slice before trusting it.
                        let partMD5 = md5Hex(of: URL(fileURLWithPath: localPart))
                        let actualMD5 = try await SFTPClient.remoteMD5(parts[index], config: config)
                        guard partMD5 == actualMD5 else {
                            throw SFTPError.commandFailed("分块 \(index) md5 不匹配")
                        }
                        report(index, .done)
                        return
                    } catch is CancellationError {
                        // Drop only the part that was in flight; verified local parts remain.
                        try? FileManager.default.removeItem(atPath: localPart)
                        _ = try? await runSSHCommand(
                            args: sshCommand(for: config) + ["rm -f \(Self.escapeShellArg(parts[index]))"],
                            config: config)
                        throw CancellationError()
                    } catch {
                        lastError = error
                        try? FileManager.default.removeItem(atPath: localPart)
                        _ = try? await runSSHCommand(
                            args: sshCommand(for: config) + ["rm -f \(Self.escapeShellArg(parts[index]))"],
                            config: config)
                        if attempt < maxAttempts {
                            try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                        }
                    }
                }
                report(index, .failed)
                throw lastError ?? SFTPError.commandFailed("分块 \(index) 下载失败")
            }

            try Task.checkCancellation()
            if isCancelled() { throw CancellationError() }

            // Concatenate the verified local parts into the destination.
            FileManager.default.createFile(atPath: localPath, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: localPath))
            defer { try? handle.close() }
            for path in localParts {
                let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
                try handle.write(contentsOf: data)
            }
            // Whole-file verification, then drop the parts.
            let localMD5 = md5Hex(of: URL(fileURLWithPath: localPath))
            let remoteMD5 = try await remoteMD5(remotePath, config: config)
            guard localMD5 == remoteMD5 else {
                throw SFTPError.commandFailed("整文件 md5 校验失败")
            }
            for path in localParts { try? FileManager.default.removeItem(atPath: path) }
            let quotedParts = parts.map { Self.escapeShellArg($0) }.joined(separator: " ")
            _ = try? await runSSHCommand(args: sshCommand(for: config) + ["rm -f \(quotedParts)"], config: config)
        } catch is CancellationError {
            // Pause/cancel: keep verified local parts for the next run.
            throw CancellationError()
        } catch {
            // Keep local parts on failure too: retry can reuse green chunks.
            throw error
        }
    }

    /// Deterministic local part path next to the destination file.
    static func localPartPath(for localPath: String, index: Int) -> String {
        "\(localPath).mtunl-part-\(String(format: "%04d", index))"
    }

    /// MD5 of `path` only when the file exists with exactly `length` bytes;
    /// nil otherwise. Guards against reusing truncated leftovers.
    static func md5HexIfComplete(_ path: String, length: Int64) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.size] as? NSNumber)?.int64Value == length else { return nil }
        return md5Hex(of: URL(fileURLWithPath: path))
    }

    /// Copies `length` bytes at `offset` from `source` into `destination`.
    private static func extractLocalSlice(source: String, destination: String,
                                          offset: Int64, length: Int64) throws {
        FileManager.default.createFile(atPath: destination, contents: nil)
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: source))
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(offset))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: destination))
        defer { try? output.close() }

        var remaining = length
        let bufferSize = 1 * 1024 * 1024
        while remaining > 0 {
            let want = Int(min(Int64(bufferSize), remaining))
            guard let data = try input.read(upToCount: want), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
        guard remaining == 0 else {
            throw SFTPError.commandFailed("本地分块读取提前结束")
        }
    }

    /// Runs `job` for every element of `jobs` with at most `workers` in
    /// flight, waiting for all to finish. The first error cancels the rest
    /// and is rethrown.
    private static func runParallel(workers: Int, jobs: Range<Int>,
                                    job: @escaping (Int) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = jobs.makeIterator()
            var running = 0
            for _ in 0..<workers {
                guard let index = iterator.next() else { break }
                running += 1
                group.addTask { try await job(index) }
            }
            while running > 0 {
                try await group.next()
                running -= 1
                if let index = iterator.next() {
                    running += 1
                    group.addTask { try await job(index) }
                }
            }
        }
    }
    
    /// Delete a remote file
    /// Delete a remote file. Without `force`, `rm` reports a missing file as
    /// an error; with it, errors are silenced by the shell flag.
    public static func deleteFile(remotePath: String, config: TunnelConfig, force: Bool = false) async throws {
        let sftpArgs = try sftpCommand(for: config)
        let flag = force ? "-f " : ""
        let batchCommands = "rm \(flag)\(Self.escapeSFTPArg(remotePath))\nbye\n"
        
        let (output, status) = try await runSFTPBatch(args: sftpArgs, batchCommands: batchCommands, config: config)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("删除失败: \(output)")
        }
    }
    
    /// Delete a remote directory and everything inside it. The sftp protocol
    /// on macOS has no recursive delete (`rmdir` only removes empty dirs), so
    /// run `rm -rf` on the remote shell over the tunnel instead. `force`
    /// controls whether `-f` is passed; without it permission problems are
    /// reported instead of silenced.
    public static func deleteDirectory(remotePath: String, config: TunnelConfig, force: Bool = false) async throws {
        let command = "rm -r\(force ? "f" : "") \(Self.escapeShellArg(remotePath))"
        let args = try sshCommand(for: config) + [command]
        
        let (output, status) = try await runSSHCommand(args: args, config: config)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("删除目录失败: \(output)")
        }
    }
    
    /// Create a remote directory
    public static func mkdir(remotePath: String, config: TunnelConfig) async throws {
        let sftpArgs = try sftpCommand(for: config)
        let batchCommands = "mkdir \(Self.escapeSFTPArg(remotePath))\nbye\n"
        
        let (output, status) = try await runSFTPBatch(args: sftpArgs, batchCommands: batchCommands, config: config)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("创建目录失败: \(output)")
        }
    }
    
    /// Rename/move a remote file or directory
    public static func rename(from oldPath: String, to newPath: String, config: TunnelConfig) async throws {
        let sftpArgs = try sftpCommand(for: config)
        let batchCommands = "rename \(Self.escapeSFTPArg(oldPath)) \(Self.escapeSFTPArg(newPath))\nbye\n"
        
        let (output, status) = try await runSFTPBatch(args: sftpArgs, batchCommands: batchCommands, config: config)
        
        guard status == 0 else {
            // Check if cross-filesystem rename failed (EXDEV error)
            if output.contains("cross-device") || output.contains("Invalid cross-device") {
                // Fallback: copy then delete
                try await copyRemote(from: oldPath, to: newPath, config: config)
                // Delete source after successful copy
                let fileInfo = try await stat(remotePath: oldPath, config: config)
                if fileInfo.isDirectory {
                    try await deleteDirectory(remotePath: oldPath, config: config)
                } else {
                    try await deleteFile(remotePath: oldPath, config: config)
                }
                return
            }
            throw SFTPError.commandFailed("重命名失败: \(output)")
        }
    }
    
    /// Copy a remote file or directory
    public static func copyRemote(from sourcePath: String, to destPath: String, config: TunnelConfig) async throws {
        let command = "cp -R \(Self.escapeShellArg(sourcePath)) \(Self.escapeShellArg(destPath))"
        let sshArgs = try sshCommand(for: config) + [command]
        
        let (output, status) = try await runSSHCommand(args: sshArgs, config: config)
        guard status == 0 else {
            throw SFTPError.commandFailed("复制失败: \(output)")
        }
    }
    
    /// Change remote file permissions
    public static func chmod(remotePath: String, permissions: String, config: TunnelConfig) async throws {
        let sftpArgs = try sftpCommand(for: config)
        let batchCommands = "chmod \(permissions) \(Self.escapeSFTPArg(remotePath))\nbye\n"
        
        let (output, status) = try await runSFTPBatch(args: sftpArgs, batchCommands: batchCommands, config: config)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("修改权限失败: \(output)")
        }
    }
    
    /// Remote archive formats offered in the UI, in menu order.
    public enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
        case tarGz = ".tar.gz"
        case tarBz2 = ".tar.bz2"
        case tarXz = ".tar.xz"
        case tar = ".tar"
        case zip = ".zip"
        case sevenZip = ".7z"

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .tarGz: return "tar.gz（兼容性最好）"
            case .tarBz2: return "tar.bz2"
            case .tarXz: return "tar.xz（压缩率最高，最慢）"
            case .tar: return "tar（仅打包，不压缩）"
            case .zip: return "zip（Windows 友好）"
            case .sevenZip: return "7z（需远端安装 7z）"
            }
        }
    }

    /// Compression strength for formats that support a level flag.
    public enum CompressionLevel: Int, CaseIterable, Identifiable, Sendable {
        case fast = 1
        case balanced = 6
        case best = 9

        public var id: Int { rawValue }
        public var label: String {
            switch self {
            case .fast: return "快（等级 \(rawValue)）"
            case .balanced: return "均衡（等级 \(rawValue)）"
            case .best: return "最小体积（等级 \(rawValue)）"
            }
        }
    }

    /// Build the remote shell command that compresses `paths` into
    /// `archivePath` with the chosen format and level, or `nil` if the
    /// arguments are invalid. Pure for unit testing.
    public static func compressCommand(
        paths: [String], archivePath: String,
        format: ArchiveFormat, level: CompressionLevel
    ) -> String? {
        guard !paths.isEmpty else { return nil }
        let targets = paths.map { escapeShellArg($0) }.joined(separator: " ")
        let archive = escapeShellArg(archivePath)

        switch format {
        case .tarGz:
            return "tar -czf \(archive) \(targets)"
        case .tarBz2:
            return "tar -cjf \(archive) \(targets)"
        case .tarXz:
            // Pass the level through to xz via XZ_OPT; tar's -J flag hides it.
            return "XZ_OPT=-\(level.rawValue) tar -cJf \(archive) \(targets)"
        case .tar:
            return "tar -cf \(archive) \(targets)"
        case .zip:
            return "zip -\(level.rawValue) -r \(archive) \(targets)"
        case .sevenZip:
            return "7z a -mx=\(level.rawValue) \(archive) \(targets)"
        }
    }

    /// Compress remote files/directories on the remote shell over the tunnel.
    public static func compress(
        remotePaths: [String], archivePath: String,
        format: ArchiveFormat = .tarGz, level: CompressionLevel = .balanced,
        config: TunnelConfig
    ) async throws {
        guard let command = compressCommand(
            paths: remotePaths, archivePath: archivePath,
            format: format, level: level
        ) else {
            throw SFTPError.commandFailed("压缩参数无效")
        }
        let args = try sshCommand(for: config) + [command]

        let (output, status) = try await runSSHCommand(args: args, config: config)

        guard status == 0 else {
            throw SFTPError.commandFailed("压缩失败: \(output)")
        }
    }
    
    /// Check if a file extension is a supported archive format
    public static func isSupportedArchive(_ path: String) -> Bool {
        extractCommand(for: path, destinationPath: "/tmp") != nil
    }

    /// Build the remote shell command that extracts `archivePath` into
    /// `destinationPath`, or `nil` when the extension is not supported.
    ///
    /// Exposed for unit testing: the command construction must stay pure and
    /// must not touch the network.
    public static func extractCommand(
        for archivePath: String, destinationPath: String, overwrite: Bool = true
    ) -> String? {
        let lower = archivePath.lowercased()
        let archive = escapeShellArg(archivePath)
        let dest = escapeShellArg(destinationPath)

        // Compound tar formats must be tested before the plain `.gz`/`.bz2`/`.xz`
        // single-file branches, otherwise `.tar.gz` would match `.gz`.
        // tar overwrites by default; extraction into the target directory is
        // the same either way, so `overwrite` only matters for zip/7z/rar.
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
            return "tar -xzf \(archive) -C \(dest)"
        }
        if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") || lower.hasSuffix(".tbz") {
            return "tar -xjf \(archive) -C \(dest)"
        }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") {
            return "tar -xJf \(archive) -C \(dest)"
        }
        if lower.hasSuffix(".tar") {
            return "tar -xf \(archive) -C \(dest)"
        }
        if lower.hasSuffix(".zip") {
            return "unzip \(overwrite ? "-o" : "-n") \(archive) -d \(dest)"
        }
        if lower.hasSuffix(".rar") {
            // unrar wants the destination directory as a separate argument;
            // the trailing slash forces extraction into that directory.
            return "unrar x \(overwrite ? "-o+" : "-o-") \(archive) \(dest)/"
        }
        if lower.hasSuffix(".7z") {
            // 7z expects -o<dir> with no space; the shell strips the quotes.
            // -y assumes yes on every prompt; -aos skips existing files.
            return "7z x \(overwrite ? "-y" : "-aos") -o\(dest) \(archive)"
        }
        if lower.hasSuffix(".gz") {
            return singleFileCommand(tool: "gunzip", suffix: ".gz",
                                     archivePath: archivePath, destinationPath: destinationPath)
        }
        if lower.hasSuffix(".bz2") {
            return singleFileCommand(tool: "bunzip2", suffix: ".bz2",
                                     archivePath: archivePath, destinationPath: destinationPath)
        }
        if lower.hasSuffix(".xz") {
            return singleFileCommand(tool: "unxz", suffix: ".xz",
                                     archivePath: archivePath, destinationPath: destinationPath)
        }
        return nil
    }

    /// Single-file compressed formats decompress to a sibling file with the
    /// compression suffix removed.
    private static func singleFileCommand(tool: String, suffix: String,
                                          archivePath: String, destinationPath: String) -> String {
        let base = (archivePath as NSString).lastPathComponent
        let stripped = base.count > suffix.count && base.hasSuffix(suffix)
            ? String(base.dropLast(suffix.count))
            : base
        let target = (destinationPath as NSString).appendingPathComponent(stripped)
        return "\(tool) -c \(escapeShellArg(archivePath)) > \(escapeShellArg(target))"
    }

    /// Decompress remote archive (supports tar.gz, tar.bz2, tar.xz, tar, zip, rar, 7z, gz, bz2, xz)
    public static func decompress(
        archivePath: String, destinationPath: String,
        overwrite: Bool = true, config: TunnelConfig
    ) async throws {
        // Detect archive format by extension and build appropriate command
        guard let command = extractCommand(
            for: archivePath, destinationPath: destinationPath, overwrite: overwrite
        ) else {
            throw SFTPError.commandFailed("不支持的压缩格式: \(archivePath)")
        }
        let args = try sshCommand(for: config) + [command]
        
        let (output, status) = try await runSSHCommand(args: args, config: config)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("解压失败: \(output)")
        }
    }
    
    /// Execute batch operations
    public static func executeBatch(_ items: [SFTPBatchItem], config: TunnelConfig) async -> [SFTPBatchItem] {
        var results = items
        
        for (index, item) in items.enumerated() {
            do {
                switch item.operation {
                case .download:
                    if let dest = item.destinationPath {
                        try await download(remotePath: item.sourcePath, localPath: dest, config: config)
                    }
                case .upload:
                    if let dest = item.destinationPath {
                        try await upload(localPath: item.sourcePath, remotePath: dest, config: config)
                    }
                case .delete:
                    try await deleteFile(remotePath: item.sourcePath, config: config)
                case .mkdir:
                    try await mkdir(remotePath: item.sourcePath, config: config)
                case .rmdir:
                    try await deleteDirectory(remotePath: item.sourcePath, config: config)
                case .rename:
                    if let dest = item.destinationPath {
                        try await rename(from: item.sourcePath, to: dest, config: config)
                    }
                case .chmod:
                    if let perms = item.destinationPath {
                        try await chmod(remotePath: item.sourcePath, permissions: perms, config: config)
                    }
                default:
                    results[index].error = "不支持的批量操作"
                    continue
                }
                results[index].completed = true
            } catch {
                results[index].error = error.localizedDescription
            }
        }
        
        return results
    }
    
    // MARK: - Private helpers
    
    static func runSSHCommand(args: [String], config: TunnelConfig) async throws -> (output: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            // Run the blocking process I/O on a global queue so neither the
            // main thread nor the cooperative pool gets stuck.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: CommandBuilder.sshPath)
                process.arguments = args
                // No environment overrides: the ControlMaster already authenticated,
                // and askpass secrets must not leak into child processes.
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                
                do {
                    try process.run()
                    
                    // Read output asynchronously to avoid pipe buffer deadlock
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: SFTPError.commandFailed(error.localizedDescription))
                }
            }
        }
    }
    
    private static func runSFTPBatch(args: [String], batchCommands: String, config: TunnelConfig, onProcessStart: ((Process) -> Void)? = nil, onProgress: ((Double) -> Void)? = nil) async throws -> (output: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
                process.arguments = ["-b", "-"] + args
                // No environment overrides: the ControlMaster already authenticated,
                // and askpass secrets must not leak into child processes.
                
                let inputPipe = Pipe()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                
                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                
                do {
                    try process.run()
                    if let onProcessStart {
                        DispatchQueue.main.async { onProcessStart(process) }
                    }
                    
                    // Write batch commands to stdin
                    if let data = batchCommands.data(using: .utf8) {
                        inputPipe.fileHandleForWriting.write(data)
                    }
                    try inputPipe.fileHandleForWriting.close()
                    
                    // Read stdout and stderr concurrently so a verbose sftp
                    // progress meter cannot block on either pipe. Progress
                    // meters use carriage returns and contain e.g. "42%".
                    let outputBox = LockedData()
                    let errorBox = LockedData()
                    let outputRead = DispatchWorkItem {
                        outputBox.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                    let errorRead = DispatchWorkItem {
                        let reader = errorPipe.fileHandleForReading
                        var pending = ""
                        while let data = try? reader.read(upToCount: 4096), !data.isEmpty {
                            errorBox.append(data)
                            guard let text = String(data: data, encoding: .utf8) else { continue }
                            pending += text
                            let lines = pending.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\r" || $0 == "\n" })
                            let hasDelimiter = pending.last == "\r" || pending.last == "\n"
                            pending = hasDelimiter ? "" : String(lines.last ?? "")
                            let completed = hasDelimiter ? lines : lines.dropLast()
                            for component in completed {
                                guard let token = component.split(separator: "%").first,
                                      let digits = token.split(whereSeparator: { !$0.isNumber }).last,
                                      let value = Double(digits), value >= 0, value <= 100 else { continue }
                                if let onProgress {
                                    DispatchQueue.main.async { onProgress(value / 100) }
                                }
                            }
                        }
                    }
                    DispatchQueue.global(qos: .utility).async(execute: outputRead)
                    DispatchQueue.global(qos: .utility).async(execute: errorRead)
                    process.waitUntilExit()
                    outputRead.wait()
                    errorRead.wait()
                    
                    let output = String(data: outputBox.data + errorBox.data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: SFTPError.commandFailed(error.localizedDescription))
                }
            }
        }
    }
    
    private static func parseDirectoryListing(_ output: String, basePath: String) throws -> [RemoteFile] {
        var files: [RemoteFile] = []
        let lines = output.split(separator: "\n")
        
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            
            let permissions = String(parts[0])
            guard permissions.count >= 10 else { continue }
            
            let isDirectory = permissions.hasPrefix("d")
            let owner = String(parts[2])
            let group = String(parts[3])
            let sizeStr = String(parts[4])
            let size = Int64(sizeStr) ?? 0
            
            // Time fields vary, join remaining parts for filename
            let timeEnd = min(8, parts.count - 1)
            let modifiedTime = parts[5..<timeEnd].joined(separator: " ")
            let name = parts[timeEnd...].joined(separator: " ")
            
            // Skip . and ..
            if name == "." || name == ".." { continue }
            
            let fullPath = basePath.hasSuffix("/") ? basePath + name : basePath + "/" + name
            
            files.append(RemoteFile(
                path: fullPath,
                name: name,
                isDirectory: isDirectory,
                size: size,
                permissions: permissions,
                owner: owner,
                group: group,
                modifiedTime: modifiedTime
            ))
        }
        
        return files
    }
    
    private static func parseStatOutput(_ output: String, path: String) throws -> RemoteFile {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard parts.count >= 6 else {
            throw SFTPError.commandFailed("无法解析 stat 输出")
        }
        
        let name = String(path.split(separator: "/").last ?? "")
        let size = Int64(parts[1]) ?? 0
        let permissions = String(parts[2])
        let owner = String(parts[3])
        let group = String(parts[4])
        let modifiedTime = String(parts[5])
        let fileType = parts.count > 6 ? String(parts[6]) : ""
        let isDirectory = fileType.contains("directory") || fileType.contains("dir")
        
        return RemoteFile(
            path: path,
            name: name,
            isDirectory: isDirectory,
            size: size,
            permissions: permissions,
            owner: owner,
            group: group,
            modifiedTime: modifiedTime
        )
    }
    
    static func escapeShellArg(_ arg: String) -> String {
        "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
    
    /// Escape an argument for use in an SFTP batch file.
    ///
    /// The SFTP batch parser does not understand POSIX shell quoting. It only
    /// honours double quotes and backslash escapes, so arguments are wrapped in
    /// double quotes with `"`, `\` and control characters escaped.
    static func escapeSFTPArg(_ arg: String) -> String {
        var escaped = "\""
        for character in arg.unicodeScalars {
            switch character {
            case "\"":
                escaped += "\\\""
            case "\\":
                escaped += "\\\\"
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                if character.value < 0x20 {
                    escaped += String(format: "\\%03o", character.value)
                } else {
                    escaped.unicodeScalars.append(character)
                }
            }
        }
        escaped += "\""
        return escaped
    }
}
