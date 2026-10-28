import CryptoKit
import Foundation

extension SFTPClient {
    /// Compute the MD5 hex digest of a local file.
    static func md5Hex(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        
        var hasher = Insecure.MD5()
        let bufferSize = 1024 * 1024
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    
    /// Compute the MD5 hex digest of a byte slice in a local file.
    static func localSliceMD5(source: String, offset: Int64, length: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: source)) else {
            return nil
        }
        defer { try? handle.close() }
        
        try? handle.seek(toOffset: UInt64(offset))
        var hasher = Insecure.MD5()
        var remaining = length
        let bufferSize = 1024 * 1024
        
        while remaining > 0 {
            let want = Int(min(Int64(bufferSize), remaining))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        
        guard remaining == 0 else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    
    /// Retrieve the MD5 hex digest of a remote file using `md5sum` or `md5 -q`.
    static func remoteMD5(_ path: String, config: TunnelConfig) async throws -> String {
        // Try md5sum (Linux/GNU), fall back to md5 -q (macOS/BSD).
        let quoted = escapeShellArg(path)
                let command = "if command -v md5sum >/dev/null 2>&1; then md5sum \(quoted) | awk '{print $1}'; else md5 -q \(quoted); fi"
        let (output, status) = try await runSSHCommand(
            args: sshCommand(for: config) + [command],
            config: config
        )
        guard status == 0 else {
            throw SFTPError.commandFailed("远端 md5 失败: \(output)")
        }
        return output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}
