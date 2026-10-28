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
}
