import MapKit
import SwiftUI

struct LockZoneSettingsCard: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @Binding var isLockZoneMapExpanded: Bool
    @State private var lockZoneMapPosition: MapCameraPosition = .automatic

    private var lockZoneMapTargetID: String {
        guard let center = controller.lockZoneCenter else { return "none" }
        return [
            String(format: "%.6f", center.latitude),
            String(format: "%.6f", center.longitude),
            String(Int(controller.lockZoneRadiusMeters.rounded()))
        ].joined(separator: ":")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let center = controller.lockZoneCenter {
                compactMap(center: center)
                locationSummary
                DistanceUnitControl(controller: controller, accent: accent)
                BluetoothTriggerControl(controller: controller, accent: accent)
                RadiusControl(controller: controller, accent: accent)
                updatedLabel
            } else {
                unsetZonePrompt
            }

            useCurrentLocationButton
        }
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "map.fill")
                .foregroundStyle(accent)
            Text("Lock Zone")
                .font(.caption.weight(.bold))
            Spacer(minLength: 8)
            Text(controller.lockZoneStatus)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private func compactMap(center: CLLocationCoordinate2D) -> some View {
        Map(position: $lockZoneMapPosition, interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: LockZoneMapGeometry.ringCoordinates(center: center, radius: controller.lockZoneRadiusMeters))
                .stroke(accent.opacity(0.28), lineWidth: 8)
                .mapOverlayLevel(level: .aboveRoads)
            MapPolyline(coordinates: LockZoneMapGeometry.ringCoordinates(center: center, radius: controller.lockZoneRadiusMeters))
                .stroke(accent.opacity(0.92), lineWidth: 2)
                .mapOverlayLevel(level: .aboveRoads)
            Marker("Lock", systemImage: "lock.fill", coordinate: center)
                .tint(accent)
            if let userLocation = controller.lockZoneUserLocation {
                Annotation("You", coordinate: userLocation, anchor: .center) {
                    UserLocationDot(accent: accent)
                }
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12))
        }
        .overlay(alignment: .bottomTrailing) {
            MapControlsOverlay(
                accent: accent,
                expand: { isLockZoneMapExpanded = true },
                center: { syncLockZoneMapCamera() }
            )
            .padding(10)
        }
        .onAppear {
            syncLockZoneMapCamera(animated: false)
            controller.startLockZoneLocationUpdates()
        }
        .onDisappear {
            controller.stopLockZoneLocationUpdates()
        }
        .onChange(of: lockZoneMapTargetID) { _, _ in
            syncLockZoneMapCamera()
            controller.refreshLockZoneLocation()
        }
    }

    private var locationSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(controller.lockZoneLocationSummary, systemImage: controller.lockZoneLocationSystemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(controller.proximityUnlockDetail, systemImage: "dot.radiowaves.left.and.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var unsetZonePrompt: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.circle.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(accent)
            Text("Unlock once to set the zone.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var updatedLabel: some View {
        if let updatedTitle = controller.lockZoneUpdatedTitle {
            Label("Updated \(updatedTitle)", systemImage: "location.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var useCurrentLocationButton: some View {
        Button {
            controller.setLockZoneToCurrentLocation()
        } label: {
            Label("Use Current Location", systemImage: "location.fill")
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .tint(accent)
    }

    private func syncLockZoneMapCamera(animated: Bool = true) {
        guard let center = controller.lockZoneCenter else { return }
        let position = MapCameraPosition.region(
            LockZoneMapGeometry.compactRegion(center: center, radius: controller.lockZoneRadiusMeters)
        )

        if animated {
            withAnimation(.easeInOut(duration: 0.24)) {
                lockZoneMapPosition = position
            }
        } else {
            lockZoneMapPosition = position
        }
    }
}

private struct UserLocationDot: View {
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.56))
                .frame(width: 28, height: 28)
            Circle()
                .fill(accent)
                .frame(width: 14, height: 14)
            Circle()
                .stroke(accent.opacity(0.75), lineWidth: 2)
                .frame(width: 24, height: 24)
        }
    }
}

private struct MapControlsOverlay: View {
    let accent: Color
    let expand: () -> Void
    let center: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: expand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand lock zone map")

            Button(action: center) {
                Image(systemName: "scope")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Center lock zone")
        }
    }
}

private struct DistanceUnitControl: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "ruler.fill")
                    .foregroundStyle(accent)
                Text("Distance Units")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.distanceUnit.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Picker("Distance Units", selection: Binding(
                get: { controller.distanceUnit },
                set: { controller.setDistanceUnit($0) }
            )) {
                ForEach(DoorUnlockerController.DistanceUnit.allCases) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct BluetoothTriggerControl: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { controller.proximityUnlockRSSIGateEnabled },
                set: { controller.setProximityUnlockRSSIGateEnabled($0) }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(accent)
                    Text("Bluetooth Trigger")
                        .font(.caption.weight(.bold))
                    Spacer(minLength: 8)
                    Text(controller.proximityUnlockRSSIThresholdTitle)
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(accent)

            if controller.proximityUnlockRSSIGateEnabled {
                Slider(
                    value: Binding(
                        get: { Double(controller.proximityUnlockRSSISliderValue) },
                        set: { controller.updateProximityUnlockRSSIThreshold(Int($0.rounded())) }
                    ),
                    in: Double(controller.proximityUnlockRSSIThresholdRange.lowerBound) ... Double(controller.proximityUnlockRSSIThresholdRange.upperBound),
                    step: 1
                )
                .tint(accent)

                HStack {
                    Text("Farther")
                    Spacer()
                    Text(controller.currentBluetoothSignalTitle)
                    Spacer()
                    Text("Closer")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RadiusControl: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Radius")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.formattedDistance(controller.lockZoneRadiusMeters))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { controller.lockZoneRadiusMeters },
                    set: { controller.updateLockZoneRadiusMeters($0) }
                ),
                in: controller.lockZoneRadiusRange,
                step: 1
            )
            .tint(accent)

            HStack {
                Text(controller.formattedDistance(controller.lockZoneRadiusRange.lowerBound))
                Spacer()
                Text(controller.formattedDistance(controller.lockZoneRadiusRange.upperBound))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }
}
