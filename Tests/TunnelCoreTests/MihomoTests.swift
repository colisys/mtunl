import XCTest
@testable import TunnelCore

final class MihomoTests: XCTestCase {
    private func fixture(_ body: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("kernel with spaces")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return (root, binary)
    }

    func testTUNRuntimeStatus() throws {
        XCTAssertTrue(try MihomoSupervisor.decodeTUNEnabled(Data(#"{"tun":{"enable":true}}"#.utf8)))
        XCTAssertFalse(try MihomoSupervisor.decodeTUNEnabled(Data(#"{"tun":{"enable":false}}"#.utf8)))
        for json in ["{}", #"{"tun":{}}"#, #"{"tun":{"enable":"true"}}"#, "<html>error</html>"] {
            XCTAssertThrowsError(try MihomoSupervisor.decodeTUNEnabled(Data(json.utf8)))
        }
        var status = MihomoStatus(state: .running)
        XCTAssertEqual(status.captureStatusText, "TUN 状态未确认")
        status.tunEnabled = false
        XCTAssertEqual(status.captureStatusText, "TUN 未启用")
        status.tunEnabled = true
        XCTAssertEqual(status.captureStatusText, "TUN 已启用")
        let legacy = try JSONDecoder().decode(MihomoStatus.self, from: Data(#"{"state":"running","log":[]}"#.utf8))
        XCTAssertNil(legacy.tunEnabled)
        XCTAssertEqual(legacy.captureStatusText, "TUN 状态未确认")
    }

    func testDownloadRequestHeaders() {
        let metadata = MihomoKernelManager.downloadRequest(MihomoKernelManager.releaseAPI, accept: "application/vnd.github+json")
        XCTAssertEqual(metadata.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(metadata.httpMethod, "GET")
        XCTAssertEqual(metadata.cachePolicy, .reloadIgnoringLocalCacheData)
        let asset = MihomoKernelManager.downloadRequest(MihomoKernelManager.releaseAPI, accept: "application/octet-stream")
        XCTAssertEqual(asset.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
    }

    func testLiveKernelDownload() throws {
        guard ProcessInfo.processInfo.environment["MTUNL_LIVE_DOWNLOAD_TEST"] == "1" else {
            throw XCTSkip("Explicit opt-in required: downloads the official kernel and executes only -v")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = MihomoKernelManager(root: root)
        let info: MihomoKernelInfo
        do { info = try manager.downloadLatestKernel() }
        catch {
            XCTFail("Live download failed: \(error.localizedDescription)")
            return
        }
        XCTAssertEqual(try MihomoKernelManager.actualVersion(at: info.path), info.version)
        XCTAssertEqual(manager.cachedInfo(), info)
        print("Verified official kernel download and -v: \(info.version)")
    }

    func testActualVersionAndFailures() throws {
        XCTAssertEqual(MihomoKernelManager.parseVersion("Mihomo Meta v1.19.0 darwin arm64"), "v1.19.0")
        XCTAssertNil(MihomoKernelManager.parseVersion("v1.19.0"))
        for (script, succeeds) in [
            ("test \"$1\" = -v || exit 1; echo 'Mihomo Meta v9 darwin arm64'", true),
            ("echo 'Mihomo Meta v9'; exit 1", false),
            ("echo unknown", false),
            ("exec /bin/sleep 5", false),
            ("while :; do echo 'xxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done", false)
        ] {
            let (root, binary) = try fixture(script)
            defer { try? FileManager.default.removeItem(at: root) }
            let start = Date()
            if succeeds {
                XCTAssertEqual(try MihomoKernelManager.actualVersion(at: binary.path), "v9")
            } else {
                XCTAssertThrowsError(try MihomoKernelManager.actualVersion(at: binary.path, timeout: 0.15, outputLimit: 128))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
    }

    func testSameTagSkipsAssetAndLocalOverrideIsOffline() throws {
        let (root, binary) = try fixture("echo 'Mihomo Meta v9 darwin arm64'")
        defer { try? FileManager.default.removeItem(at: root) }
        let info = MihomoKernelInfo(version: "v9", path: binary.path)
        try JSONEncoder().encode(info).write(to: root.appendingPathComponent("current.json"))
        var requests = [URL]()
        let manager = MihomoKernelManager(root: root) { url in
            requests.append(url)
            return Data(#"{"tag_name":"v9","assets":[]}"#.utf8)
        }
        XCTAssertEqual(try manager.resolveBinary(override: binary.path).path, binary.path)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(try manager.downloadLatestKernel(), info)
        XCTAssertEqual(requests, [MihomoKernelManager.releaseAPI])
        try FileManager.default.removeItem(at: binary)
        XCTAssertNil(manager.cachedInfo())
        XCTAssertThrowsError(try manager.downloadLatestKernel())
    }

    func testMirrorContractAndLegacyStatusButtons() throws {
        let upstream = MihomoKernelManager.releaseAPI
        XCTAssertEqual(try MihomoKernelManager.requestURL(upstream, mirrorURL: "https://mirror.example/proxy/").absoluteString,
                       "https://mirror.example/proxy/" + upstream.absoluteString)
        XCTAssertEqual(try MihomoKernelManager.requestURL(upstream, mirrorURL: ""), upstream)
        XCTAssertEqual(try MihomoKernelManager.requestURL(upstream, mirrorURL: "https://mirror.example" ).absoluteString,
                       "https://mirror.example/" + upstream.absoluteString)
        for invalid in ["http://mirror.example/", "https://mirror.example/?q=", "https://u:p@mirror.example/"] {
            XCTAssertThrowsError(try MihomoKernelManager.requestURL(upstream, mirrorURL: invalid))
        }
        var status = try JSONDecoder().decode(MihomoStatus.self, from: Data(#"{"state":"stopped","log":[]}"#.utf8))
        XCTAssertNil(status.actualVersion)
        XCTAssertEqual(status.downloadButtonTitle, "下载内核")
        status.cachedKernel = MihomoKernelInfo(version: "tag", path: "/unused")
        XCTAssertEqual(status.downloadButtonTitle, "更新内核")
        status.downloadInProgress = true
        XCTAssertEqual(status.downloadButtonTitle, "检查 / 下载中…")
        XCTAssertEqual(try JSONDecoder().decode(MihomoSettings.self, from: Data("{}".utf8)).mirrorURL, "")
    }

    func testDownloadDoesNotBlockStatusAndDeduplicates() throws {
        let (root, _) = try fixture("exit 1")
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "request entered once")
        entered.assertForOverFulfill = true
        let release = DispatchSemaphore(value: 0)
        let manager = MihomoKernelManager(root: root) { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
            throw MihomoKernelError.releaseUnavailable
        }
        let supervisor = MihomoSupervisor(kernelManager: manager)
        supervisor.downloadKernel()
        wait(for: [entered], timeout: 1)
        let start = Date()
        supervisor.downloadKernel()
        XCTAssertEqual(supervisor.currentStatus().downloadInProgress, true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        release.signal()
        let deadline = Date().addingTimeInterval(2)
        while supervisor.currentStatus().downloadInProgress == true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(supervisor.currentStatus().downloadInProgress, false)
        XCTAssertEqual(supervisor.currentStatus().state, .stopped)
        XCTAssertNotNil(supervisor.currentStatus().downloadMessage)
    }

    private func dynamic() -> TunnelConfig {
        TunnelConfig(name: "ssh socks", kind: .dynamic, host: "example.com", user: "deval",
                     bindAddress: "127.0.0.1", listenPort: 1080)
    }

    func testYamlUsesGeneralRulesAndSelectedSSHOutbound() throws {
        let settings = MihomoSettings(dynamicTunnelID: dynamic().id, rules: [
            "IP-CIDR,10.0.0.0/8,no-resolve",
            "IP-CIDR6,2001:db8::/32,no-resolve",
            "DOMAIN-SUFFIX,example.com",
            "GEOSITE,geolocation-!cn",
            "DST-PORT,443",
            "PROCESS-NAME,Telegram",
            "AND,((NETWORK,UDP),(DST-PORT,443))"
        ], mixedPort: 17890)
        let yaml = try MihomoConfigBuilder.yaml(settings: settings, socksPort: 1080)
        XCTAssertTrue(yaml.contains("server: 127.0.0.1"))
        XCTAssertTrue(yaml.contains("port: 1080"))
        XCTAssertTrue(yaml.contains("udp: false"))
        XCTAssertTrue(yaml.contains("- \"IP-CIDR,10.0.0.0/8,MTunl SSH Group,no-resolve\""))
        XCTAssertTrue(yaml.contains("- \"IP-CIDR6,2001:db8::/32,MTunl SSH Group,no-resolve\""))
        XCTAssertTrue(yaml.contains("- \"DOMAIN-SUFFIX,example.com,MTunl SSH Group\""))
        XCTAssertTrue(yaml.contains("- \"GEOSITE,geolocation-!cn,MTunl SSH Group\""))
        XCTAssertTrue(yaml.contains("- \"DST-PORT,443,MTunl SSH Group\""))
        XCTAssertTrue(yaml.contains("- \"PROCESS-NAME,Telegram,MTunl SSH Group\""))
        XCTAssertTrue(yaml.contains("- \"AND,((NETWORK,UDP),(DST-PORT,443)),MTunl SSH Group\""))
        XCTAssertTrue(yaml.contains("- MATCH,DIRECT"))
        XCTAssertTrue(yaml.contains("auto-route: true"))
        XCTAssertTrue(yaml.contains("name: MTunl SSH Group"))
    }

    func testValidationRequiresDynamicTunnelAndSafeRules() throws {
        let tunnel = dynamic()
        let settings = MihomoSettings(dynamicTunnelID: tunnel.id, rules: ["DOMAIN-SUFFIX,example.com"])
        XCTAssertThrowsError(try MihomoConfigBuilder.validate(settings, tunnels: [
            tunnel.withKind(.local)
        ])) { error in
            XCTAssertEqual(error as? MihomoError, .tunnelMustBeDynamic)
        }
        for invalid in [[], ["DOMAIN-SUFFIX,"], ["DOMAIN,example.com,DIRECT"], ["MATCH,DIRECT"],
                        ["DOMAIN,example.com\nexternal-controller: 0.0.0.0:80"], ["DOMAIN,,example.com"]] {
            XCTAssertThrowsError(try MihomoConfigBuilder.validate(
                MihomoSettings(dynamicTunnelID: tunnel.id, rules: invalid), tunnels: [tunnel]
            ), "\(invalid)")
        }
        XCTAssertNoThrow(try MihomoConfigBuilder.validate(
            MihomoSettings(dynamicTunnelID: tunnel.id, rules: ["IP-CIDR,10.0.0.0/8,no-resolve", "IP-CIDR6,2001:db8::/32"]),
            tunnels: [tunnel]
        ))
    }

    func testLegacyCIDRSettingsMigrateToGeneralRules() throws {
        let old = #"{"cidrs":["10.0.0.0/8","2001:db8::/32"]}"#
        let settings = try JSONDecoder().decode(MihomoSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.rules, ["IP-CIDR,10.0.0.0/8,no-resolve", "IP-CIDR6,2001:db8::/32,no-resolve"])
        let saved = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertTrue(saved.contains("\"rules\""))
        XCTAssertFalse(saved.contains("\"cidrs\""))
    }

    func testMissingTunnelIsRejected() {
        let settings = MihomoSettings(dynamicTunnelID: UUID(), rules: ["IP-CIDR,10.0.0.0/8"])
        XCTAssertThrowsError(try MihomoConfigBuilder.validate(settings, tunnels: [])) { error in
            XCTAssertEqual(error as? MihomoError, .tunnelNotFound)
        }
    }
}

private extension TunnelConfig {
    func withKind(_ kind: TunnelKind) -> TunnelConfig {
        var copy = self
        copy.kind = kind
        return copy
    }
}
