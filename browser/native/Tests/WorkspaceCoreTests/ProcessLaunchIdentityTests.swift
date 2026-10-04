import Foundation
import WorkspaceCore
import XCTest

final class ProcessLaunchIdentityTests: XCTestCase {
    func testDirectProcessGetsStableKernelIdentityAndExitInvalidatesIt() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Pipe(); child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        let launch = try XCTUnwrap(processLaunchDate(child.processIdentifier))
        XCTAssertEqual(processLaunchDate(child.processIdentifier), launch)
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        XCTAssertNil(processLaunchDate(child.processIdentifier))
        XCTAssertNil(processLaunchDate(-1))
    }
}
