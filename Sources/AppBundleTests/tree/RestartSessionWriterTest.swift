@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class RestartSessionWriterTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testNewerFinalSnapshotRejectsLateCheckpointAndPreservesBackup() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let writer = RestartSessionWriter()
        let first = RestartSessionSnapshot.capture(now: Date(timeIntervalSince1970: 100))
        TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let final = RestartSessionSnapshot.capture(now: Date(timeIntervalSince1970: 200))
        let saved = try await writer.write(final, to: file, revision: 2)
        XCTAssertEqual(saved?.didWrite, true)
        let late = try await writer.write(first, to: file, revision: 1)
        XCTAssertNil(late)
        XCTAssertEqual(try file.read()?.savedAt, final.savedAt)

        let unchanged = try await writer.write(RestartSessionSnapshot.capture(), to: file, revision: 3)
        XCTAssertEqual(unchanged?.didWrite, false)
        XCTAssertEqual(unchanged?.snapshot.savedAt, final.savedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.backupURL.path))

        TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        let next = RestartSessionSnapshot.capture(now: Date(timeIntervalSince1970: 300))
        try await writer.write(next, to: file, revision: 4)
        XCTAssertEqual(try file.read()?.savedAt, next.savedAt)
        XCTAssertEqual(try JSONDecoder().decode(RestartSessionSnapshot.self, from: Data(contentsOf: file.backupURL)).savedAt, final.savedAt)
    }

    func testFailedWriteCanRetryAndEqualContentStillWritesToANewLocation() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let writer = RestartSessionWriter()
        let snapshot = RestartSessionSnapshot.capture()
        // A directory occupying the destination causes the atomic replacement to fail.
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
        do {
            try await writer.write(snapshot, to: file, revision: 1)
            XCTFail("Expected an unwritable destination to report failure")
        } catch {}
        try FileManager.default.removeItem(at: file.url)
        let retried = try await writer.write(snapshot, to: file, revision: 2)
        XCTAssertEqual(retried?.didWrite, true)
        let other = RestartSessionFile(url: file.url.appendingPathExtension("other"))
        let moved = try await writer.write(snapshot, to: other, revision: 3)
        XCTAssertEqual(moved?.didWrite, true)
        XCTAssertEqual(try other.read()?.savedAt, snapshot.savedAt)
    }

    func testDiskWriteDoesNotBlockMainActor() async throws {
        let started = expectation(description: "Background write started")
        let release = DispatchSemaphore(value: 0)
        // Bound the test even if a regression moves a blocking write back to the main actor.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }
        let writer = RestartSessionWriter { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            release.wait()
        }
        let snapshot = RestartSessionSnapshot.capture()
        let file = temporaryFile()
        let save = Task { try await writer.write(snapshot, to: file, revision: 1) }
        await fulfillment(of: [started], timeout: 1)
        let mainActorWork = Task { @MainActor in 42 }
        let result = await mainActorWork.value
        XCTAssertEqual(result, 42)
        release.signal()
        let saved = try await save.value
        XCTAssertEqual(saved?.didWrite, true)
    }

    private func temporaryFile() -> RestartSessionFile {
        RestartSessionFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("winmux-writer-\(UUID().uuidString)")
            .appendingPathComponent("window-state.json"))
    }
}
