import Foundation
import Darwin
import TunnelCore

do {
    try PrivilegedHelper.run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
