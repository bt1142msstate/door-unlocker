import CoreLocation
import MapKit
import SwiftUI

struct LockZoneExpandedMapContent: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @Binding var mapPosition: MapCameraPosition
    let routeCoordinates: [CLLocationCoordinate2D]?

    var body: some View {
        if let center = controller.lockZoneCenter {
            Map(
                position: $mapPosition,
                interactionModes: [.pan, .zoom]
            ) {
                MapPolyline(coordinates: LockZoneMapGeometry.ringCoordinates(center: center, radius: controller.lockZoneRadiusMeters))
                    .stroke(accent.opacity(0.28), lineWidth: 12)
                    .mapOverlayLevel(level: .aboveRoads)
                MapPolyline(coordinates: LockZoneMapGeometry.ringCoordinates(center: center, radius: controller.lockZoneRadiusMeters))
                    .stroke(accent.opacity(0.92), lineWidth: 3)
                    .mapOverlayLevel(level: .aboveRoads)

                if let routeCoordinates {
                    MapPolyline(coordinates: routeCoordinates)
                        .stroke(accent.opacity(0.74), lineWidth: 4)
                        .mapOverlayLevel(level: .aboveRoads)
                }

                Marker(controller.lockName, systemImage: "lock.fill", coordinate: center)
                    .tint(accent)

                if let userLocation = controller.lockZoneUserLocation {
                    Annotation("You", coordinate: userLocation, anchor: .center) {
                        LockZoneUserLocationMarker(accent: accent)
                    }
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()
        } else {
            LockZoneUnavailableView(accent: accent)
        }
    }
}

private struct LockZoneUserLocationMarker: View {
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.62))
                .frame(width: 36, height: 36)
            Circle()
                .fill(accent)
                .frame(width: 16, height: 16)
            Circle()
                .stroke(accent.opacity(0.72), lineWidth: 3)
                .frame(width: 30, height: 30)
        }
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

private struct LockZoneUnavailableView: View {
    let accent: Color

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(accent)
            Text("Lock zone not set")
                .font(.title3.weight(.bold))
            Text("Unlock once or use current location to set the zone.")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LockZoneDirectionCue: View {
    let accent: Color
    let directionPulse: Bool
    let isDirectionArrowActive: Bool
    let smoothedArrowDegrees: Double
    let directionIconName: String
    let guidanceTitle: String
    let guidanceDetail: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isDirectionArrowActive {
                    Circle()
                        .stroke(accent.opacity(0.28), lineWidth: 2)
                        .frame(width: 58, height: 58)
                        .scaleEffect(directionPulse ? 1.18 : 0.86)
                        .opacity(directionPulse ? 0.12 : 0.62)
                        .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: false), value: directionPulse)
                }

                Circle()
                    .fill(accent.opacity(0.22))
                    .frame(width: 48, height: 48)

                Image(systemName: directionIconName)
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(accent)
                    .rotationEffect(.degrees(isDirectionArrowActive ? smoothedArrowDegrees : 0))
                    .animation(.spring(response: 0.34, dampingFraction: 0.82), value: smoothedArrowDegrees)
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 3) {
                Text(guidanceTitle)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(guidanceDetail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accent.opacity(0.24), lineWidth: 1)
        }
    }
}

struct LockZoneExpandedTopBar: View {
    let lockName: String
    let onClose: () -> Void
    let onCenter: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.66), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close map")

            VStack(alignment: .leading, spacing: 2) {
                Text(lockName)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("Lock zone")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onCenter) {
                Image(systemName: "scope")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.66), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Center map")
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12))
        }
    }
}
