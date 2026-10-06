import Foundation
import WorkspaceCore
import XCTest

@MainActor
final class WorkspaceBrowserLifetimeTests: XCTestCase {
    private func process() throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        addTeardownBlock { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        return child
    }

    func testReconnectDoesNotStopLiveOwnerAndActualProcessExitStopsOnce() async throws {
        let child = try process(), launch = Date()
        let stopped = expectation(description: "Workspace stops after browser exits")
        var stops = 0
        let lifetime = WorkspaceBrowserLifetime { stops += 1; stopped.fulfill() }
        XCTAssertTrue(lifetime.observe(processID: child.processIdentifier, launch: launch))
        XCTAssertFalse(lifetime.observe(processID: child.processIdentifier, launch: launch))
        await Task.yield()
        XCTAssertEqual(stops, 0)
        child.terminate()
        await fulfillment(of: [stopped], timeout: 3)
        lifetime.confirmExit(processID: child.processIdentifier, launch: launch)
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(lifetime.hasRequestedStop)
        XCTAssertFalse(lifetime.observe(processID: child.processIdentifier, launch: launch))
    }

    func testOtherBrowserOwnerKeepsWorkspaceAliveUntilLastProcessExits() async throws {
        let first = try process(), second = try process(), launch = Date()
        let stopped = expectation(description: "Last owner exited")
        let lifetime = WorkspaceBrowserLifetime { stopped.fulfill() }
        lifetime.observe(processID: first.processIdentifier, launch: launch)
        lifetime.observe(processID: second.processIdentifier, launch: launch)
        first.terminate()
        first.waitUntilExit()
        lifetime.confirmExit(processID: first.processIdentifier, launch: launch)
        XCTAssertFalse(lifetime.hasRequestedStop)
        second.terminate()
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertTrue(lifetime.hasRequestedStop)
    }

    func testStaleExitCannotStopReplacementProcessOrUnstartedWorkspace() throws {
        let child = try process(), previous = Date(), replacement = Date().addingTimeInterval(1)
        let lifetime = WorkspaceBrowserLifetime { XCTFail("No matching process has exited") }
        lifetime.confirmExit(processID: child.processIdentifier, launch: previous)
        XCTAssertFalse(lifetime.hasRequestedStop)
        lifetime.observe(processID: child.processIdentifier, launch: previous)
        lifetime.observe(processID: child.processIdentifier, launch: replacement)
        lifetime.confirmExit(processID: child.processIdentifier, launch: previous)
        XCTAssertFalse(lifetime.hasRequestedStop)
    }
}
