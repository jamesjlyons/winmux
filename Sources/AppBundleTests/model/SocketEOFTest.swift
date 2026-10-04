import Common
import Foundation
import Network
import XCTest

@MainActor
final class SocketEOFTest: XCTestCase {
    func testCleanEOFAndTruncatedHeaderTerminateTheRead() async throws {
        for packet in [Data(), Data([3, 0])] {
            let result = try await readPacketEndingAtEOF(packet)
            XCTAssertEqual(result.failureOrNil, .posix(.ECONNRESET))
        }
    }

    func testEOFInPayloadTerminatesTheRead() async throws {
        var packet = withUnsafeBytes(of: UInt32(5)) { Data($0) }
        packet.append(contentsOf: [1, 2])
        let result = try await readPacketEndingAtEOF(packet)
        XCTAssertEqual(result.failureOrNil, .posix(.ECONNRESET))
    }

    func testCompletePayloadDeliveredWithEOFStillSucceeds() async throws {
        let payload = Data([1, 2, 3])
        var packet = withUnsafeBytes(of: UInt32(payload.count)) { Data($0) }
        packet.append(payload)
        let result = try await readPacketEndingAtEOF(packet)
        XCTAssertEqual(try result.get(), payload)
    }

    private func readPacketEndingAtEOF(_ packet: Data) async throws -> Result<Data, NWError> {
        let ready = expectation(description: "Listener ready")
        let listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { peer in
            peer.start(queue: .global())
            peer.send(content: packet, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in })
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 2)
        let port = try XCTUnwrap(listener.port)
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        defer { connection.cancel() }
        let start = await connection.startBlocking()
        XCTAssertNil(start.error)
        // Bound a regression that repeatedly receives EOF: cancellation yields
        // ECANCELED, which fails the expected ECONNRESET assertion above.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { connection.cancel() }
        }
        defer { watchdog.cancel() }
        return await connection.readNonAtomic()
    }
}
