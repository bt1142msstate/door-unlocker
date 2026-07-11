import XCTest
@testable import DoorUnlockerShared

final class DoorControllerFreshnessTrackerTests: XCTestCase {
    func testMetadataSnapshotRequiresEveryAuthoritativeField() {
        var tracker = DoorControllerFreshnessTracker()
        XCTAssertFalse(tracker.hasCompleteMetadataSnapshot(hasCurrentFirmwareVersion: false))

        XCTAssertTrue(tracker.receiveBootSession("boot-a"))
        XCTAssertTrue(tracker.receiveStorageHealth("ok"))
        XCTAssertTrue(tracker.receiveStateSnapshot())
        XCTAssertFalse(tracker.hasCompleteMetadataSnapshot(hasCurrentFirmwareVersion: true))

        XCTAssertTrue(tracker.receiveConnectionRoster())
        XCTAssertFalse(tracker.hasCompleteMetadataSnapshot(hasCurrentFirmwareVersion: false))
        XCTAssertTrue(tracker.hasCompleteMetadataSnapshot(hasCurrentFirmwareVersion: true))
    }

    func testSnapshotCannotBecomeCurrentBeforeBootIdentity() {
        var tracker = DoorControllerFreshnessTracker()

        XCTAssertFalse(tracker.receiveStateSnapshot())
        XCTAssertFalse(tracker.receiveConnectionRoster())
        XCTAssertFalse(tracker.receiveStorageHealth("ok"))
        XCTAssertFalse(tracker.hasAuthoritativeState)
    }

    func testNewBootSessionRevokesAllPriorTruth() {
        var tracker = readyTracker(session: "boot-a")
        XCTAssertTrue(tracker.hasAuthoritativeState)

        XCTAssertTrue(tracker.receiveBootSession("boot-b"))
        XCTAssertEqual(tracker.bootSessionIdentifier, "boot-b")
        XCTAssertEqual(tracker.storageHealth, .unknown)
        XCTAssertFalse(tracker.hasCurrentStateSnapshot)
        XCTAssertFalse(tracker.hasCurrentConnectionRoster)
        XCTAssertFalse(tracker.hasAuthoritativeState)
    }

    func testDuplicateBootMarkerDoesNotEraseCurrentSnapshot() {
        var tracker = readyTracker(session: "boot-a")
        let generation = tracker.generation

        XCTAssertFalse(tracker.receiveBootSession("boot-a"))
        XCTAssertEqual(tracker.generation, generation)
        XCTAssertTrue(tracker.hasAuthoritativeState)
        XCTAssertTrue(tracker.hasCurrentConnectionRoster)
    }

    func testTransportInvalidationRevokesEveryCurrentFact() {
        var tracker = readyTracker(session: "boot-a")
        tracker.invalidateTransport()

        XCTAssertNil(tracker.bootSessionIdentifier)
        XCTAssertEqual(tracker.storageHealth, .unknown)
        XCTAssertFalse(tracker.hasCurrentStateSnapshot)
        XCTAssertFalse(tracker.hasCurrentConnectionRoster)
        XCTAssertFalse(tracker.hasAuthoritativeState)
    }

    func testStorageFaultNeverProducesAuthoritativeState() {
        var tracker = DoorControllerFreshnessTracker()
        XCTAssertTrue(tracker.receiveBootSession("boot-a"))
        XCTAssertTrue(tracker.receiveStorageHealth("storage_fault"))
        XCTAssertTrue(tracker.receiveStateSnapshot())

        XCTAssertEqual(tracker.storageHealth, .storageFault)
        XCTAssertFalse(tracker.hasAuthoritativeState)
    }

    func testDeterministicChaosNeverRetainsTruthAcrossInvalidationOrNewBoot() {
        var tracker = DoorControllerFreshnessTracker()
        var random = DeterministicRandom(seed: 0xD00D_2026)
        var expectedBoot: String?

        for step in 0..<250_000 {
            switch random.next() % 7 {
            case 0:
                tracker.invalidateTransport()
                expectedBoot = nil
            case 1:
                let boot = "boot-\(random.next() % 32)"
                let changed = tracker.receiveBootSession(boot)
                if changed {
                    expectedBoot = boot
                    XCTAssertFalse(tracker.hasCurrentStateSnapshot, "step \(step)")
                    XCTAssertFalse(tracker.hasCurrentConnectionRoster, "step \(step)")
                    XCTAssertEqual(tracker.storageHealth, .unknown, "step \(step)")
                }
            case 2:
                _ = tracker.receiveStorageHealth("ok")
            case 3:
                _ = tracker.receiveStorageHealth("storage_fault")
            case 4:
                _ = tracker.receiveStateSnapshot()
            case 5:
                _ = tracker.receiveConnectionRoster()
            default:
                _ = tracker.receiveStorageHealth("garbled")
            }

            XCTAssertEqual(tracker.bootSessionIdentifier, expectedBoot, "step \(step)")
            if tracker.hasAuthoritativeState {
                XCTAssertNotNil(tracker.bootSessionIdentifier, "step \(step)")
                XCTAssertEqual(tracker.storageHealth, .ok, "step \(step)")
                XCTAssertTrue(tracker.hasCurrentStateSnapshot, "step \(step)")
            }
            if tracker.bootSessionIdentifier == nil {
                XCTAssertFalse(tracker.hasCurrentStateSnapshot, "step \(step)")
                XCTAssertFalse(tracker.hasCurrentConnectionRoster, "step \(step)")
                XCTAssertEqual(tracker.storageHealth, .unknown, "step \(step)")
            }
        }
    }

    private func readyTracker(session: String) -> DoorControllerFreshnessTracker {
        var tracker = DoorControllerFreshnessTracker()
        XCTAssertTrue(tracker.receiveBootSession(session))
        XCTAssertTrue(tracker.receiveStorageHealth("ok"))
        XCTAssertTrue(tracker.receiveStateSnapshot())
        XCTAssertTrue(tracker.receiveConnectionRoster())
        return tracker
    }
}

private struct DeterministicRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
