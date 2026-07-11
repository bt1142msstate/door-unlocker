import XCTest
@testable import DoorUnlockerShared

final class DoorControllerSessionAssessmentTests: XCTestCase {
    func testReadyRequiresEveryAuthoritativeSessionFact() {
        let ready = DoorControllerSessionAssessment.assess(readyFacts())

        XCTAssertEqual(ready.phase, .ready)
        XCTAssertTrue(ready.isControllerOnline)
        XCTAssertTrue(ready.isDisplayedStateAuthoritative)
        XCTAssertTrue(ready.canDispatchImmediately)
        XCTAssertFalse(ready.canQueueCommand)
    }

    func testQueueableOfflineSessionNeverClaimsOnlineOrReady() {
        var facts = readyFacts()
        facts.link = .scanning
        facts.isTransportConnected = false
        facts.isGattReady = false
        facts.isLinkAuthenticated = false
        facts.hasCurrentStateSnapshot = false
        facts.hasFreshCommandMaterial = false
        facts.canQueueCommand = true

        let assessment = DoorControllerSessionAssessment.assess(facts)

        XCTAssertEqual(assessment.phase, .scanning)
        XCTAssertFalse(assessment.isControllerOnline)
        XCTAssertFalse(assessment.isDisplayedStateAuthoritative)
        XCTAssertFalse(assessment.canDispatchImmediately)
        XCTAssertTrue(assessment.canQueueCommand)
    }

    func testConnectedSessionDistinguishesAuthenticationSnapshotAndNonce() {
        var facts = readyFacts()
        facts.isLinkAuthenticated = false
        XCTAssertEqual(DoorControllerSessionAssessment.assess(facts).phase, .authenticating)

        facts.isLinkAuthenticated = true
        facts.hasCurrentStateSnapshot = false
        XCTAssertEqual(DoorControllerSessionAssessment.assess(facts).phase, .synchronizing)

        facts.hasCurrentStateSnapshot = true
        facts.hasFreshCommandMaterial = false
        XCTAssertEqual(DoorControllerSessionAssessment.assess(facts).phase, .preparingSecureControl)
    }

    func testBluetoothFailuresOverrideCachedTrustAndLinkHints() {
        for (availability, phase) in [
            (DoorBluetoothAvailability.poweredOff, DoorControllerSessionPhase.bluetoothOff),
            (.unauthorized, .permissionNeeded),
            (.unsupported, .unsupported),
            (.resetting, .bluetoothResetting),
            (.unknown, .starting)
        ] {
            var facts = readyFacts()
            facts.bluetooth = availability
            let assessment = DoorControllerSessionAssessment.assess(facts)
            XCTAssertEqual(assessment.phase, phase)
            XCTAssertFalse(assessment.isControllerOnline)
            XCTAssertFalse(assessment.isDisplayedStateAuthoritative)
            XCTAssertFalse(assessment.canDispatchImmediately)
        }
    }

    func testFirmwareUpdateOverridesNormalSessionFacts() {
        var facts = readyFacts()
        facts.link = .updatingFirmware

        let assessment = DoorControllerSessionAssessment.assess(facts)

        XCTAssertEqual(assessment.phase, .updatingFirmware)
        XCTAssertFalse(assessment.canDispatchImmediately)
    }

    func testAllFactCombinationsRespectSafetyInvariants() {
        let booleans = [false, true]
        for bluetooth in DoorBluetoothAvailability.allCases {
            for link in DoorControllerLinkPhase.allCases {
                for connected in booleans {
                    for gatt in booleans {
                        for trusted in booleans {
                            for authenticated in booleans {
                                for snapshot in booleans {
                                    for commandMaterial in booleans {
                                        for queueable in booleans {
                                            let facts = DoorControllerSessionFacts(
                                                bluetooth: bluetooth,
                                                link: link,
                                                isTransportConnected: connected,
                                                isGattReady: gatt,
                                                isTrusted: trusted,
                                                isLinkAuthenticated: authenticated,
                                                hasCurrentStateSnapshot: snapshot,
                                                hasFreshCommandMaterial: commandMaterial,
                                                canQueueCommand: queueable
                                            )
                                            let assessment = DoorControllerSessionAssessment.assess(facts)
                                            assertSafetyInvariants(assessment, facts: facts)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func assertSafetyInvariants(
        _ assessment: DoorControllerSessionAssessment,
        facts: DoorControllerSessionFacts,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if assessment.phase == .ready {
            XCTAssertEqual(facts.bluetooth, .available, file: file, line: line)
            XCTAssertTrue(facts.isTransportConnected, file: file, line: line)
            XCTAssertTrue(facts.isGattReady, file: file, line: line)
            XCTAssertTrue(facts.isTrusted, file: file, line: line)
            XCTAssertTrue(facts.isLinkAuthenticated, file: file, line: line)
            XCTAssertTrue(facts.hasCurrentStateSnapshot, file: file, line: line)
            XCTAssertTrue(facts.hasFreshCommandMaterial, file: file, line: line)
        }

        if assessment.isDisplayedStateAuthoritative {
            XCTAssertTrue(assessment.isControllerOnline, file: file, line: line)
            XCTAssertTrue(facts.hasCurrentStateSnapshot, file: file, line: line)
        }

        XCTAssertFalse(
            assessment.canDispatchImmediately && assessment.canQueueCommand,
            file: file,
            line: line
        )
    }

    private func readyFacts() -> DoorControllerSessionFacts {
        DoorControllerSessionFacts(
            bluetooth: .available,
            link: .connected,
            isTransportConnected: true,
            isGattReady: true,
            isTrusted: true,
            isLinkAuthenticated: true,
            hasCurrentStateSnapshot: true,
            hasFreshCommandMaterial: true,
            canQueueCommand: true
        )
    }
}
