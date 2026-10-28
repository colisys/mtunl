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
    
    /// Build SFTP connection arguments using existing SSH tunnel's control socket
    public static func sftpCommand(for config: TunnelConfig) throws -> [String] {
        let socketPath = CommandBuilder.sshControlPath(for: config)
        var args = [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(socketPath)",
            "-o", "StrictHostKeyChecking=ask",
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
    
    /// Build SSH command arguments for running remote commands
    private static func sshCommand(for config: TunnelConfig) throws -> [String] {
        let socketPath = CommandBuilder.sshControlPath(for: config)
        var args = [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(socketPath)",
            "-o", "StrictHostKeyChecking=ask",
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
    
    /// Download a file from remote to local
    public static func download(remotePath: String, localPath: String, config: TunnelConfig, onProcessStart: ((Process) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let sftpArgs = try sftpCommand(for: config)
        let batchCommands = "get -r \(Self.escapeSFTPArg(remotePath)) \(Self.escapeSFTPArg(localPath))\nbye\n"
        
        let (output, status) = try await runSFTPBatch(args: sftpArgs, batchCommands: batchCommands, config: config, onProcessStart: onProcessStart)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("下载失败: \(output)")
        }
    }
    
    /// Upload a file from local to remote
    public static func upload(localPath: String, remotePath: String, config: TunnelConfig, onProcessStart: ((Process) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let sftpArgs = try sftpCommand(for: config)
        let batchCommands = "put -r \(Self.escapeSFTPArg(localPath)) \(Self.escapeSFTPArg(remotePath))\nbye\n"
        
        let (output, status) = try await runSFTPBatch(args: sftpArgs, batchCommands: batchCommands, config: config, onProcessStart: onProcessStart)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("上传失败: \(output)")
        }
    }
    
    /// Delete a remote file
    public static func deleteFile(remotePath: String, config: TunnelConfig) async throws {
        let sftpArgs = try sftpCommand(for: config)
        let batchCommands = "rm \(Self.escapeSFTPArg(remotePath))\nbye\n"
        
        let (output, status) = try await runSFTPBatch(args: sftpArgs, batchCommands: batchCommands, config: config)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("删除失败: \(output)")
        }
    }
    
    /// Delete a remote directory
    public static func deleteDirectory(remotePath: String, config: TunnelConfig) async throws {
        let sftpArgs = try sftpCommand(for: config)
        let batchCommands = "rmdir \(Self.escapeSFTPArg(remotePath))\nbye\n"
        
        let (output, status) = try await runSFTPBatch(args: sftpArgs, batchCommands: batchCommands, config: config)
        
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
    
    /// Compress remote files/directories using tar
    public static func compress(remotePaths: [String], archivePath: String, config: TunnelConfig) async throws {
        let socketPath = CommandBuilder.sshControlPath(for: config)
        var args = [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(socketPath)",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        
        if let port = config.sshPort {
            args += ["-p", String(port)]
        }
        if let identity = config.identityFile, !identity.isEmpty {
            args += ["-i", identity]
        }
        if let jump = config.jumpHost, !jump.isEmpty {
            args += ["-J", jump]
        }
        
        let paths = remotePaths.map { Self.escapeShellArg($0) }.joined(separator: " ")
        let command = "tar -czf \(Self.escapeShellArg(archivePath)) \(paths)"
        args += ["--", config.destination, command]
        
        let (output, status) = try await runSSHCommand(args: args, config: config)
        
        guard status == 0 else {
            throw SFTPError.commandFailed("压缩失败: \(output)")
        }
    }
    
    /// Decompress remote archive using tar
    public static func decompress(archivePath: String, destinationPath: String, config: TunnelConfig) async throws {
        let socketPath = CommandBuilder.sshControlPath(for: config)
        var args = [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(socketPath)",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        
        if let port = config.sshPort {
            args += ["-p", String(port)]
        }
        if let identity = config.identityFile, !identity.isEmpty {
            args += ["-i", identity]
        }
        if let jump = config.jumpHost, !jump.isEmpty {
            args += ["-J", jump]
        }
        
        let command = "tar -xzf \(Self.escapeShellArg(archivePath)) -C \(Self.escapeShellArg(destinationPath))"
        args += ["--", config.destination, command]
        
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
    
    private static func runSSHCommand(args: [String], config: TunnelConfig) async throws -> (output: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            // Run the blocking process I/O on a global queue so neither the
            // main thread nor the cooperative pool gets stuck.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: CommandBuilder.sshPath)
                process.arguments = args
                if let env = try? MTunlKeychain.askpassEnvironment(for: config) {
                    process.environment = env
                }
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                
                do {
                    try process.run()
                    
                    // Read output asynchronously to avoid pipe buffer deadlock
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    MTunlKeychain.cleanupAskpassScript()
                    
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    MTunlKeychain.cleanupAskpassScript()
                    continuation.resume(throwing: SFTPError.commandFailed(error.localizedDescription))
                }
            }
        }
    }
    
    private static func runSFTPBatch(args: [String], batchCommands: String, config: TunnelConfig, onProcessStart: ((Process) -> Void)? = nil) async throws -> (output: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
                process.arguments = ["-b", "-"] + args
                if let env = try? MTunlKeychain.askpassEnvironment(for: config) {
                    process.environment = env
                }
                
                let inputPipe = Pipe()
                let outputPipe = Pipe()
                
                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = outputPipe
                
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
                    
                    // Read output asynchronously to avoid pipe buffer deadlock
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    MTunlKeychain.cleanupAskpassScript()
                    
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    MTunlKeychain.cleanupAskpassScript()
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
    
    private static func escapeShellArg(_ arg: String) -> String {
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
