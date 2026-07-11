import Foundation

public enum DoorSecureNonceAcceptancePolicy {
    public static func shouldAccept(
        receivedNonce: Data,
        lastConsumedNonce: Data?
    ) -> Bool {
        receivedNonce != lastConsumedNonce
    }
}
