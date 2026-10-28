import XCTest
@testable import TunnelCore

final class SFTPClientTests: XCTestCase {
    
    func testEscapeSFTPArg() throws {
        // Basic ASCII path
        XCTAssertEqual(SFTPClient.escapeSFTPArg("/home/user/file.txt"), "\"/home/user/file.txt\"")
        
        // Path with spaces
        XCTAssertEqual(SFTPClient.escapeSFTPArg("/home/user/my file.txt"), "\"/home/user/my file.txt\"")
        
        // Path with double quotes
        XCTAssertEqual(SFTPClient.escapeSFTPArg("/home/user/\"quoted\".txt"), "\"/home/user/\\\"quoted\\\".txt\"")
        
        // Path with backslashes
        XCTAssertEqual(SFTPClient.escapeSFTPArg("/home/user/back\\slash.txt"), "\"/home/user/back\\\\slash.txt\"")
        
        // Path with newline
        XCTAssertEqual(SFTPClient.escapeSFTPArg("/home/user/new\nline.txt"), "\"/home/user/new\\nline.txt\"")
        
        // Path with tab
        XCTAssertEqual(SFTPClient.escapeSFTPArg("/home/user/tab\there.txt"), "\"/home/user/tab\\there.txt\"")
        
        // Path with single quotes (should NOT be escaped for SFTP)
        XCTAssertEqual(SFTPClient.escapeSFTPArg("/home/user/'single'.txt"), "\"/home/user/'single'.txt\"")
        
        // Unicode path
        XCTAssertEqual(SFTPClient.escapeSFTPArg("/home/user/文件.txt"), "\"/home/user/文件.txt\"")
        
        // Mixed special characters
        XCTAssertEqual(
            SFTPClient.escapeSFTPArg("/home/user/\"test\" file\\path.txt"),
            "\"/home/user/\\\"test\\\" file\\\\path.txt\""
        )
    }
    
    func testIsSupportedArchive() throws {
        // Supported tar formats
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.tar.gz"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.tgz"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.tar.bz2"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.tbz2"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.tbz"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.tar.xz"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.txz"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.tar"))
        
        // Supported other formats
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.zip"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.rar"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.7z"))
        
        // Single-file compression
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.gz"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.bz2"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/file.xz"))
        
        // Case insensitive
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/FILE.TAR.GZ"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/Archive.ZIP"))
        XCTAssertTrue(SFTPClient.isSupportedArchive("/path/to/File.Rar"))
        
        // Unsupported formats
        XCTAssertFalse(SFTPClient.isSupportedArchive("/path/to/file.txt"))
        XCTAssertFalse(SFTPClient.isSupportedArchive("/path/to/file.pdf"))
        XCTAssertFalse(SFTPClient.isSupportedArchive("/path/to/file.iso"))
        XCTAssertFalse(SFTPClient.isSupportedArchive("/path/to/file"))
        
        // Edge cases
        XCTAssertTrue(SFTPClient.isSupportedArchive("file.tar.gz"))  // No path
        XCTAssertTrue(SFTPClient.isSupportedArchive(".tar.gz"))      // Hidden file
        XCTAssertFalse(SFTPClient.isSupportedArchive(""))            // Empty string
    }
    
    func testExtractCommand() throws {
        // tar.gz variants
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "/path/archive.tar.gz", destinationPath: "/dest"),
            "tar -xzf '/path/archive.tar.gz' -C '/dest'"
        )
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "backup.tgz", destinationPath: "/tmp"),
            "tar -xzf 'backup.tgz' -C '/tmp'"
        )
        
        // tar.bz2 variants
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "backup.tar.bz2", destinationPath: "/dest"),
            "tar -xjf 'backup.tar.bz2' -C '/dest'"
        )
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "backup.tbz2", destinationPath: "/dest"),
            "tar -xjf 'backup.tbz2' -C '/dest'"
        )
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "backup.tbz", destinationPath: "/dest"),
            "tar -xjf 'backup.tbz' -C '/dest'"
        )
        
        // tar.xz variants
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "backup.tar.xz", destinationPath: "/dest"),
            "tar -xJf 'backup.tar.xz' -C '/dest'"
        )
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "backup.txz", destinationPath: "/dest"),
            "tar -xJf 'backup.txz' -C '/dest'"
        )
        
        // Plain tar
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "backup.tar", destinationPath: "/dest"),
            "tar -xf 'backup.tar' -C '/dest'"
        )
        
        // zip
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "archive.zip", destinationPath: "/dest"),
            "unzip -o 'archive.zip' -d '/dest'"
        )
        
        // rar
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "archive.rar", destinationPath: "/dest"),
            "unrar x -o+ 'archive.rar' '/dest'/"
        )
        
        // 7z
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "archive.7z", destinationPath: "/dest"),
            "7z x -y -o'/dest' 'archive.7z'"
        )
        
        // Single-file compression: .gz
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "/data/file.txt.gz", destinationPath: "/dest"),
            "gunzip -c '/data/file.txt.gz' > '/dest/file.txt'"
        )
        // Edge case: .gz with no base name before the suffix
        XCTAssertEqual(
            SFTPClient.extractCommand(for: ".gz", destinationPath: "/dest"),
            "gunzip -c '.gz' > '/dest/.gz'"
        )
        
        // Single-file compression: .bz2
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "/data/file.txt.bz2", destinationPath: "/dest"),
            "bunzip2 -c '/data/file.txt.bz2' > '/dest/file.txt'"
        )
        
        // Single-file compression: .xz
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "/data/file.txt.xz", destinationPath: "/dest"),
            "unxz -c '/data/file.txt.xz' > '/dest/file.txt'"
        )
        
        // Compound suffix precedence: .tar.gz must not match the single-file .gz branch
        let tarGzCmd = SFTPClient.extractCommand(for: "backup.tar.gz", destinationPath: "/dest")
        XCTAssertTrue(tarGzCmd!.contains("tar -xzf"))
        XCTAssertFalse(tarGzCmd!.contains("gunzip"))

        // Overwrite=false changes the flags for archive tools with explicit modes
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "archive.zip", destinationPath: "/dest", overwrite: false),
            "unzip -n 'archive.zip' -d '/dest'"
        )
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "archive.rar", destinationPath: "/dest", overwrite: false),
            "unrar x -o- 'archive.rar' '/dest'/"
        )
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "archive.7z", destinationPath: "/dest", overwrite: false),
            "7z x -aos -o'/dest' 'archive.7z'"
        )
        // tar overwrites unconditionally; the flag must not appear
        XCTAssertFalse(
            SFTPClient.extractCommand(for: "backup.tar", destinationPath: "/dest", overwrite: false)!.contains("-n")
        )
        
        // Case insensitivity
        XCTAssertNotNil(SFTPClient.extractCommand(for: "FILE.TAR.GZ", destinationPath: "/dest"))
        XCTAssertNotNil(SFTPClient.extractCommand(for: "Archive.ZIP", destinationPath: "/dest"))
        
        // Unsupported formats return nil
        XCTAssertNil(SFTPClient.extractCommand(for: "file.txt", destinationPath: "/dest"))
        XCTAssertNil(SFTPClient.extractCommand(for: "file.pdf", destinationPath: "/dest"))
        XCTAssertNil(SFTPClient.extractCommand(for: "file.iso", destinationPath: "/dest"))
        XCTAssertNil(SFTPClient.extractCommand(for: "file", destinationPath: "/dest"))
        XCTAssertNil(SFTPClient.extractCommand(for: "", destinationPath: "/dest"))
        
        // Paths with special characters are properly escaped
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "/path with spaces/archive.tar.gz", destinationPath: "/dest with spaces"),
            "tar -xzf '/path with spaces/archive.tar.gz' -C '/dest with spaces'"
        )
        XCTAssertEqual(
            SFTPClient.extractCommand(for: "/path/ar'chive.zip", destinationPath: "/de'st"),
            "unzip -o '/path/ar'\\''chive.zip' -d '/de'\\''st'"
        )
    }

    // MARK: - Compress command construction

    func testCompressCommandFormats() {
        let paths = ["/data/logs", "/data/file with space.txt"]
        let escaped = "'/data/logs' '/data/file with space.txt'"

        XCTAssertEqual(
            SFTPClient.compressCommand(paths: paths, archivePath: "/out/a.tar.gz",
                                       format: .tarGz, level: .best),
            "tar -czf '/out/a.tar.gz' \(escaped)"
        )
        XCTAssertEqual(
            SFTPClient.compressCommand(paths: paths, archivePath: "/out/a.tar.bz2",
                                       format: .tarBz2, level: .fast),
            "tar -cjf '/out/a.tar.bz2' \(escaped)"
        )
        XCTAssertEqual(
            SFTPClient.compressCommand(paths: paths, archivePath: "/out/a.tar.xz",
                                       format: .tarXz, level: .best),
            "XZ_OPT=-9 tar -cJf '/out/a.tar.xz' \(escaped)"
        )
        XCTAssertEqual(
            SFTPClient.compressCommand(paths: paths, archivePath: "/out/a.tar",
                                       format: .tar, level: .best),
            "tar -cf '/out/a.tar' \(escaped)"
        )
        XCTAssertEqual(
            SFTPClient.compressCommand(paths: paths, archivePath: "/out/a.zip",
                                       format: .zip, level: .fast),
            "zip -1 -r '/out/a.zip' \(escaped)"
        )
        XCTAssertEqual(
            SFTPClient.compressCommand(paths: paths, archivePath: "/out/a.7z",
                                       format: .sevenZip, level: .balanced),
            "7z a -mx=6 '/out/a.7z' \(escaped)"
        )
    }

    func testCompressCommandRejectsEmptyPaths() {
        XCTAssertNil(SFTPClient.compressCommand(
            paths: [], archivePath: "/out/a.tar.gz", format: .tarGz, level: .balanced))
    }

    // MARK: - Chunked transfer

    func testChunkRangesCoverTheFileExactly() {
        // Exact multiples, remainder, and boundaries.
        XCTAssertTrue(SFTPClient.chunkRanges(size: 0).isEmpty)
        XCTAssertTrue(SFTPClient.chunkRanges(size: -1).isEmpty)

        let chunk = SFTPClient.chunkSize
        XCTAssertEqual(
            SFTPClient.chunkRanges(size: chunk).map { [Int64($0.offset), Int64($0.length)] },
            [[0, chunk]]
        )
        XCTAssertEqual(
            SFTPClient.chunkRanges(size: chunk + 1).map { [Int64($0.offset), Int64($0.length)] },
            [[0, chunk], [chunk, 1]]
        )
        XCTAssertEqual(
            SFTPClient.chunkRanges(size: 3 * chunk + 7).map { [Int64($0.offset), Int64($0.length)] },
            [[0, chunk], [chunk, chunk], [2 * chunk, chunk], [3 * chunk, 7]]
        )

        // Invariants: contiguous coverage, no gaps or overlaps.
        let ranges = SFTPClient.chunkRanges(size: 100 * 1024 * 1024 + 123)
        XCTAssertEqual(ranges.reduce(Int64(0)) { $0 + $1.length }, 100 * 1024 * 1024 + 123)
        for (first, second) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(first.offset + first.length, second.offset)
        }
    }

    func testPartPathsAreUniqueAndDeterministic() {
        XCTAssertEqual(SFTPClient.partPath(for: "/a/b.zip", index: 3), "/a/b.zip.mtunl-part-0003")
        XCTAssertNotEqual(SFTPClient.partPath(for: "/a/b.zip", index: 1),
                          SFTPClient.partPath(for: "/a/b.zip", index: 2))
    }
}
