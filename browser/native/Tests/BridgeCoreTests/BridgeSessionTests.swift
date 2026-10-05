import BridgeCore
import XCTest

final class BridgeSessionTests: XCTestCase {
    func testHandshakeRequiredAndUnsupportedVersionRejected() {
        let session = BridgeSession()
        XCTAssertFalse(session.accept(epoch: "invented", sequence: 1))
        XCTAssertNil(session.negotiate(version: 7))
        let epoch = session.negotiate(version: 1)!
        XCTAssertTrue(session.accept(epoch: epoch, sequence: 1))
    }

    func testVersionOneCannotPublishInventoryOrUpgradeAnExistingEpoch() {
        let legacy = BridgeSession()
        let epoch = legacy.negotiate(version: 1)!
        XCTAssertFalse(legacy.accept(epoch: epoch, sequence: 1, minimumVersion: 2))
        XCTAssertNil(legacy.negotiate(version: 2))
        XCTAssertTrue(legacy.accept(epoch: epoch, sequence: 1))
        let current = BridgeSession()
        let currentEpoch = current.negotiate(version: 2)!
        XCTAssertTrue(current.accept(epoch: currentEpoch, sequence: 1, minimumVersion: 2))
    }

    func testVersionFourEnablesNavigationWithoutWideningLegacyEpochs() {
        let current = BridgeSession()
        let epoch = current.negotiate(version: 4)!
        XCTAssertTrue(current.accept(epoch: epoch, sequence: 1, minimumVersion: 4))
        let previous = BridgeSession()
        let oldEpoch = previous.negotiate(version: 3)!
        XCTAssertFalse(previous.accept(epoch: oldEpoch, sequence: 1, minimumVersion: 4))
        XCTAssertTrue(previous.accept(epoch: oldEpoch, sequence: 1, minimumVersion: 3))
        XCTAssertNil(previous.negotiate(version: 4))
    }

    func testVersionFiveEnablesCreationWithoutUpgradingExistingEpochs() {
        let current = BridgeSession(), legacy = BridgeSession()
        let epoch = current.negotiate(version: 5)!
        XCTAssertTrue(current.accept(epoch: epoch, sequence: 1, minimumVersion: 5))
        let old = legacy.negotiate(version: 4)!
        XCTAssertFalse(legacy.accept(epoch: old, sequence: 1, minimumVersion: 5))
        XCTAssertNil(legacy.negotiate(version: 5))
    }

    func testDuplicateStaleAndForeignMessagesRejected() {
        let session = BridgeSession()
        let epoch = session.negotiate(version: 1)!
        XCTAssertTrue(session.accept(epoch: epoch, sequence: 7))
        XCTAssertFalse(session.accept(epoch: epoch, sequence: 7))
        XCTAssertFalse(session.accept(epoch: epoch, sequence: 6))
        XCTAssertFalse(session.accept(epoch: UUID().uuidString, sequence: 8))
        XCTAssertTrue(session.accept(epoch: epoch, sequence: 8))
    }

    func testVersionSixEnablesProfilesWithoutUpgradingExistingEpochs() {
        let current = BridgeSession(), previous = BridgeSession()
        let epoch = current.negotiate(version: 6)!
        XCTAssertTrue(current.accept(epoch: epoch, sequence: 1, minimumVersion: 6))
        let old = previous.negotiate(version: 5)!
        XCTAssertFalse(previous.accept(epoch: old, sequence: 1, minimumVersion: 6))
        XCTAssertNil(previous.negotiate(version: 6))
    }

    func testReconnectRotatesEpochAndRenegotiationDoesNotResetSequence() {
        let first = BridgeSession()
        let epoch = first.negotiate(version: 1)!
        XCTAssertTrue(first.accept(epoch: epoch, sequence: 42))
        XCTAssertEqual(first.negotiate(version: 1), epoch)
        XCTAssertFalse(first.accept(epoch: epoch, sequence: 1))
        let second = BridgeSession()
        XCTAssertNotEqual(second.negotiate(version: 1), epoch)
        XCTAssertFalse(second.accept(epoch: epoch, sequence: 43))
    }

    func testRequirementsCannotBeInjectedOrAcceptAdHocIdentities() {
        XCTAssertNil(SigningIdentity.requirement(identifier: "arbitrary.client", teamID: "W9C2P3N7Q2"))
        XCTAssertNil(SigningIdentity.requirement(identifier: SigningIdentity.browserID, teamID: "-"))
        XCTAssertNil(SigningIdentity.requirement(identifier: SigningIdentity.browserID, teamID: "\" or true"))
        XCTAssertNotNil(SigningIdentity.requirement(identifier: SigningIdentity.helperID, teamID: "W9C2P3N7Q2"))
    }
}
