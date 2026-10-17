import Foundation
import Darwin

public struct MihomoKernelInfo: Codable, Equatable, Sendable {
    public let version: String
    public let path: String
    public let downloadedAt: Date

    public init(version: String, path: String, downloadedAt: Date = Date()) {
        self.version = version
        self.path = path
        self.downloadedAt = downloadedAt
    }
}

public enum MihomoKernelError: LocalizedError, Equatable {
    case unsupportedArchitecture
    case network(String)
    case releaseUnavailable
    case assetUnavailable(String)
    case archive(String)
    case invalidBinary
    case kernelNotDownloaded

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture: return "当前 macOS 架构没有可用的 Mihomo 内核"
        case .network(let message): return "下载 Mihomo 失败：\(message)"
        case .releaseUnavailable: return "无法获取 Mihomo 最新版本信息"
        case .assetUnavailable(let name): return "Mihomo 发布包中没有找到适用于当前架构的文件：\(name)"
        case .archive(let message): return "解压 Mihomo 失败：\(message)"
        case .invalidBinary: return "下载的 Mihomo 文件不是可执行文件"
        case .kernelNotDownloaded: return "尚未下载 Mihomo 内核，请先点击“下载内核”"
        }
    }
}

/// Downloads the official Mihomo release on demand. No Homebrew or external
/// package manager is required. The downloaded file is cached per user.
public final class MihomoKernelManager: @unchecked Sendable {
    public static let releaseAPI = URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")!
    private let fileManager: FileManager
    private let root: URL
    private let lock = NSLock()
    private let transport: ((URL) throws -> Data)?

    public init(root: URL = MihomoKernelManager.defaultRoot, fileManager: FileManager = .default,
                    transport: ((URL) throws -> Data)? = nil) {
            self.transport = transport
        self.root = root
        self.fileManager = fileManager
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MTunl/kernels/mihomo")
    }

    public func cachedInfo() -> MihomoKernelInfo? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("current.json")) else { return nil }
        guard let info = try? JSONDecoder().decode(MihomoKernelInfo.self, from: data),
              fileManager.isExecutableFile(atPath: info.path) else { return nil }
        return info
    }

    /// Resolves a manually configured or already cached kernel. This method
    /// never accesses the network.
    public func resolveBinary(override: String?) throws -> MihomoKernelInfo {
        if let override, !override.isEmpty {
            guard override.hasPrefix("/"), fileManager.isExecutableFile(atPath: override) else {
                throw MihomoKernelError.invalidBinary
            }
            return MihomoKernelInfo(version: "外部路径", path: override)
        }
        if let cached = cachedInfo(), fileManager.isExecutableFile(atPath: cached.path) { return cached }
        throw MihomoKernelError.kernelNotDownloaded
    }

    /// Downloads and caches the latest official release. This is an explicit
    /// user action; starting Mihomo never calls it implicitly.
    public func downloadLatestKernel(mirrorURL: String = "") throws -> MihomoKernelInfo {
        lock.lock()
        defer { lock.unlock() }
        return try downloadLatest(mirrorURL: mirrorURL)
    }

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    public static func requestURL(_ upstream: URL, mirrorURL: String) throws -> URL {
        guard !mirrorURL.isEmpty else { return upstream }
        let normalized = mirrorURL.hasSuffix("/") ? mirrorURL : mirrorURL + "/"
        guard let prefix = URLComponents(string: normalized), prefix.scheme == "https",
              prefix.host != nil, prefix.user == nil, prefix.password == nil,
              prefix.query == nil, prefix.fragment == nil,
              let url = URL(string: normalized + upstream.absoluteString) else {
            throw MihomoError.invalid("镜像必须是 HTTPS 地址，不能包含认证信息、查询参数或片段")
        }
        return url
    }

    private func downloadLatest(mirrorURL: String) throws -> MihomoKernelInfo {
        let metadataURL = try Self.requestURL(Self.releaseAPI, mirrorURL: mirrorURL)
        let releaseData = try request(metadataURL, accept: "application/vnd.github+json", stage: "获取版本信息")
        guard let release = try? JSONDecoder().decode(Release.self, from: releaseData) else {
            throw MihomoKernelError.network("获取版本信息：响应不是有效的 Releases JSON；地址：\(metadataURL.absoluteString)。如果使用镜像，请确认它支持 GitHub API，而非仅支持文件下载。")
        }
        if let cached = cachedInfo(), cached.version == release.tag_name {
            // Execute -v to reject stale/corrupt caches before skipping the asset.
            if (try? Self.actualVersion(at: cached.path)) != nil { return cached }
        }
        let suffix: String
        #if arch(arm64)
        suffix = "darwin-arm64"
        #elseif arch(x86_64)
        suffix = "darwin-amd64"
        #else
        throw MihomoKernelError.unsupportedArchitecture
        #endif
        guard let asset = release.assets.first(where: {
            $0.name.lowercased().contains(suffix) && ($0.name.hasSuffix(".gz") || $0.name.hasSuffix(".zip"))
        }), let url = URL(string: asset.browser_download_url) else {
            throw MihomoKernelError.assetUnavailable(suffix)
        }
        let archive = try request(Self.requestURL(url, mirrorURL: mirrorURL), accept: "application/octet-stream", stage: "下载内核文件")
        // Never overwrite an existing executable, even for a repaired same-tag cache.
        let directory = root.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        var installed = false
        defer { if !installed { try? fileManager.removeItem(at: directory) } }
        let archiveURL = directory.appendingPathComponent("release." + (asset.name.hasSuffix(".zip") ? "zip" : "gz"))
        try archive.write(to: archiveURL, options: .atomic)
        let binaryURL = directory.appendingPathComponent("mihomo")
        try extract(archiveURL: archiveURL, binaryURL: binaryURL)
        guard fileManager.isExecutableFile(atPath: binaryURL.path) else { throw MihomoKernelError.invalidBinary }
        _ = try Self.actualVersion(at: binaryURL.path)
        let info = MihomoKernelInfo(version: release.tag_name, path: binaryURL.path)
        let encoded = try JSONEncoder().encode(info)
        try encoded.write(to: root.appendingPathComponent("current.json"), options: .atomic)
        installed = true
        return info
    }

    private func request(_ url: URL, accept: String, stage: String) throws -> Data {
        if let transport { return try transport(url) }
        let request = Self.downloadRequest(url, accept: accept)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request) { data, response, error in

            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            guard let http = response as? HTTPURLResponse else {
                result = .failure(MihomoKernelError.network("服务器返回的不是 HTTP 响应；请求地址：\(url.absoluteString)"))
                return
            }
            guard (200..<300).contains(http.statusCode), let data else {
                let body = data.map { String(decoding: $0.prefix(200), as: UTF8.self) } ?? ""
                let detail = body.isEmpty ? "无响应内容" : body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                result = .failure(MihomoKernelError.network("HTTP \(http.statusCode)，地址：\(url.absoluteString)，响应：\(detail)"))
                return
            }
            result = .success(data)
        }.resume()
        semaphore.wait()
        do { return try result.get() }
        catch { throw MihomoKernelError.network("\(stage)：\(error.localizedDescription)；请求地址：\(url.absoluteString)") }
    }

    static func downloadRequest(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("MTunl/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    public static func parseVersion(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.count >= 3, words[0].lowercased() == "mihomo",
               words[1].lowercased() == "meta" { return String(words[2]) }
        }
        return nil
    }

    /// Bounded nonblocking reads also handle children that keep the pipe open.
    public static func actualVersion(at path: String, timeout: TimeInterval = 2,
                                     outputLimit: Int = 16_384) throws -> String {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = ["-v"]
        child.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        try child.run()
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MihomoError.process("版本查询超时")
            }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= outputLimit else {
                    throw MihomoError.process("版本查询输出超过限制")
                }
                output.append(contentsOf: buffer.prefix(count))
            } else if !child.isRunning {
                break
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        guard child.terminationStatus == 0,
              let version = parseVersion(String(decoding: output, as: UTF8.self)) else {
            throw MihomoError.process("无法获取实际版本（退出码 \(child.terminationStatus)）")
        }
        return version
    }

    private func extract(archiveURL: URL, binaryURL: URL) throws {
        if archiveURL.pathExtension == "zip" {
            let result = run("/usr/bin/ditto", ["-x", "-k", archiveURL.path, binaryURL.deletingLastPathComponent().path])
            guard result.status == 0 else { throw MihomoKernelError.archive(result.output) }
            if !fileManager.fileExists(atPath: binaryURL.path) {
                let candidates = (try? fileManager.contentsOfDirectory(atPath: binaryURL.deletingLastPathComponent().path)) ?? []
                guard let candidate = candidates.first(where: { $0.contains("mihomo") }) else { throw MihomoKernelError.invalidBinary }
                try fileManager.moveItem(at: binaryURL.deletingLastPathComponent().appendingPathComponent(candidate), to: binaryURL)
            }
        } else {
            let result = run("/usr/bin/gunzip", ["-c", archiveURL.path])
            guard result.status == 0 else { throw MihomoKernelError.archive(result.output) }
            try result.data.write(to: binaryURL, options: .atomic)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binaryURL.path)
    }

    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String, data: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), data)
    }
}
