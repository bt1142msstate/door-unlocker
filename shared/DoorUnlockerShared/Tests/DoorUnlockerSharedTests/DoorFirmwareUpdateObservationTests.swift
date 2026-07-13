import DoorUnlockerShared
import Foundation
import Testing

struct DoorFirmwareUpdateObservationTests {
    @Test func updateRemainsActiveUntilFinished() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var observation = DoorFirmwareUpdateObservation()

        observation.begin(at: startedAt)

        #expect(observation.isActive)
        let expiredEarly = observation.expire(at: startedAt.addingTimeInterval(179))
        #expect(!expiredEarly)
        observation.finish()
        #expect(!observation.isActive)
    }

    @Test func staleUpdateExpires() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var observation = DoorFirmwareUpdateObservation(announcedAt: startedAt)

        let expired = observation.expire(at: startedAt.addingTimeInterval(180))
        #expect(expired)
        #expect(!observation.isActive)
    }

    @Test func updateTracksUpdaterAndEstimatedProgress() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var observation = DoorFirmwareUpdateObservation()

        observation.begin(updaterName: "iPhone Air", at: startedAt, estimatedDuration: 20)
        observation.tick(at: startedAt.addingTimeInterval(5))

        #expect(observation.updaterName == "iPhone Air")
        #expect(observation.estimatedProgress == 25)
        #expect(observation.estimatedSecondsRemaining == 15)

        observation.tick(at: startedAt.addingTimeInterval(21))
        #expect(observation.estimatedProgress == 95)
        #expect(observation.estimatedSecondsRemaining == nil)
    }
}
