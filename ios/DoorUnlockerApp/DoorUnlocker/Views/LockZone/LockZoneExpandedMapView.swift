import CoreLocation
import MapKit
import SwiftUI

struct LockZoneExpandedMapView: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    @Environment(\.dismiss) private var dismiss
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var directionPulse = false
    @State private var smoothedArrowDegrees = 0.0
    @State private var hasSmoothedArrow = false

    private enum DirectionSource: String {
        case movement
        case compass
        case map
        case unavailable
    }

    private var routeCoordinates: [CLLocationCoordinate2D]? {
        guard let center = controller.lockZoneCenter,
              let userLocation = controller.lockZoneUserLocation else {
            return nil
        }

        return [userLocation, center]
    }

    private var guidance: LockZoneMapGeometry.Guidance? {
        guard let center = controller.lockZoneCenter,
              let userLocation = controller.lockZoneUserLocation else {
            return nil
        }

        return LockZoneMapGeometry.guidance(from: userLocation, to: center)
    }

    private var mapTargetID: String {
        guard let center = controller.lockZoneCenter else { return "none" }
        let userLocation = controller.lockZoneUserLocation
        return [
            String(format: "%.6f", center.latitude),
            String(format: "%.6f", center.longitude),
            String(format: "%.5f", userLocation?.latitude ?? 0),
            String(format: "%.5f", userLocation?.longitude ?? 0),
            String(Int(controller.lockZoneRadiusMeters.rounded()))
        ].joined(separator: ":")
    }

    private var directionSampleID: String {
        [
            directionSource.rawValue,
            String(format: "%.1f", guidance?.bearingDegrees ?? 0),
            String(format: "%.1f", controller.lockZoneCourseDegrees ?? -1),
            String(format: "%.1f", controller.lockZoneHeadingDegrees ?? -1),
            String(controller.lockZoneBluetoothRSSI ?? -999)
        ].joined(separator: ":")
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .ignoresSafeArea()

            LockZoneExpandedMapContent(
                controller: controller,
                accent: accent,
                mapPosition: $mapPosition,
                routeCoordinates: routeCoordinates
            )

            VStack(spacing: 12) {
                LockZoneExpandedTopBar(
                    lockName: controller.lockName,
                    onClose: { dismiss() },
                    onCenter: { syncMapCamera() }
                )
                LockZoneDirectionCue(
                    accent: accent,
                    directionPulse: directionPulse,
                    isDirectionArrowActive: isDirectionArrowActive,
                    smoothedArrowDegrees: smoothedArrowDegrees,
                    directionIconName: directionIconName,
                    guidanceTitle: guidanceTitle,
                    guidanceDetail: guidanceDetail
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            syncMapCamera(animated: false)
            controller.startLockZoneLocationUpdates()
            controller.startLockZoneDirectionUpdates()
            controller.refreshLockZoneLocation()
            updateSmoothedArrow(animated: false)
            directionPulse = true
        }
        .onDisappear {
            controller.stopLockZoneDirectionUpdates()
        }
        .onChange(of: mapTargetID) { _, _ in
            syncMapCamera()
        }
        .onChange(of: directionSampleID) { _, _ in
            updateSmoothedArrow()
        }
    }

    private var directionIconName: String {
        if let guidance,
           guidance.distanceMeters <= max(controller.lockZoneRadiusMeters, 5) {
            return "checkmark"
        }

        return guidance == nil ? "location.fill" : "arrow.up"
    }

    private var isDirectionArrowActive: Bool {
        directionIconName == "arrow.up"
    }

    private var isBluetoothNearby: Bool {
        controller.isBluetoothSignalStrongForGuidance
    }

    private var directionSource: DirectionSource {
        guard guidance != nil else { return .unavailable }

        if let speed = controller.lockZoneSpeedMetersPerSecond,
           speed >= 0.8,
           let course = controller.lockZoneCourseDegrees,
           course >= 0,
           let courseAccuracy = controller.lockZoneCourseAccuracyDegrees,
           courseAccuracy <= 55 {
            return .movement
        }

        if let heading = controller.lockZoneHeadingDegrees,
           heading >= 0,
           let headingAccuracy = controller.lockZoneHeadingAccuracyDegrees,
           headingAccuracy <= 40 {
            return .compass
        }

        return .map
    }

    private var rawArrowRotationDegrees: Double {
        guard let guidance else { return 0 }

        switch directionSource {
        case .movement:
            return LockZoneMapGeometry.relativeArrowDegrees(
                targetBearingDegrees: guidance.bearingDegrees,
                phoneHeadingDegrees: controller.lockZoneCourseDegrees ?? guidance.bearingDegrees
            )
        case .compass:
            return LockZoneMapGeometry.relativeArrowDegrees(
                targetBearingDegrees: guidance.bearingDegrees,
                phoneHeadingDegrees: controller.lockZoneHeadingDegrees ?? guidance.bearingDegrees
            )
        case .map:
            return guidance.bearingDegrees
        case .unavailable:
            return 0
        }
    }

    private var guidanceTitle: String {
        guard let guidance else { return "Finding your position" }

        if isBluetoothNearby {
            return "Controller nearby"
        }

        if guidance.distanceMeters <= max(controller.lockZoneRadiusMeters, 5) {
            return "Inside lock zone"
        }

        return "\(controller.formattedDistance(guidance.distanceMeters)) from lock"
    }

    private var guidanceDetail: String {
        guard guidance != nil else {
            return "Keep this screen open while your location updates."
        }

        if isBluetoothNearby {
            return "Bluetooth signal is strong. GPS is no longer the main signal."
        }

        let accuracyText = controller.lockZoneUserAccuracyMeters.map {
            " GPS +/-\(controller.formattedDistance($0))."
        } ?? ""

        switch directionSource {
        case .movement:
            return "Arrow follows your walking direction.\(accuracyText)"
        case .compass:
            return "Arrow follows where your phone is facing.\(accuracyText)"
        case .map:
            return "Compass/course settling. Arrow is map-based.\(accuracyText)"
        case .unavailable:
            return "Keep this screen open while your location updates."
        }
    }

    private func updateSmoothedArrow(animated: Bool = true) {
        let target = rawArrowRotationDegrees
        let nextValue: Double

        if hasSmoothedArrow {
            nextValue = LockZoneMapGeometry.interpolatedDegrees(
                from: smoothedArrowDegrees,
                to: target,
                factor: directionSource == .movement ? 0.42 : 0.28
            )
        } else {
            hasSmoothedArrow = true
            nextValue = target
        }

        if animated {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                smoothedArrowDegrees = nextValue
            }
        } else {
            smoothedArrowDegrees = nextValue
        }
    }

    private func syncMapCamera(animated: Bool = true) {
        guard let center = controller.lockZoneCenter else { return }
        let position = MapCameraPosition.region(
            LockZoneMapGeometry.expandedRegion(
                center: center,
                radius: controller.lockZoneRadiusMeters,
                userLocation: controller.lockZoneUserLocation
            )
        )

        if animated {
            withAnimation(.easeInOut(duration: 0.28)) {
                mapPosition = position
            }
        } else {
            mapPosition = position
        }
    }
}
