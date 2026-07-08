import CoreLocation
import MapKit

enum LockZoneMapGeometry {
    struct Guidance {
        let bearingDegrees: Double
        let distanceMeters: CLLocationDistance
    }

    static func compactRegion(center: CLLocationCoordinate2D, radius: CLLocationDistance) -> MKCoordinateRegion {
        let spanMeters = min(max(radius * 5, 40), 900)
        return MKCoordinateRegion(center: center, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
    }

    static func expandedRegion(
        center: CLLocationCoordinate2D,
        radius: CLLocationDistance,
        userLocation: CLLocationCoordinate2D?
    ) -> MKCoordinateRegion {
        guard let userLocation else {
            let spanMeters = min(max(radius * 7, 90), 2_500)
            return MKCoordinateRegion(center: center, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
        }

        let distance = distanceMeters(from: userLocation, to: center)
        let latitude = (center.latitude + userLocation.latitude) / 2
        let longitude = (center.longitude + userLocation.longitude) / 2
        let midpoint = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let spanMeters = min(max(distance * 2.7, radius * 6, 90), 3_500)

        return MKCoordinateRegion(center: midpoint, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
    }

    static func ringCoordinates(center: CLLocationCoordinate2D, radius: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard CLLocationCoordinate2DIsValid(center), radius > 0 else { return [] }

        let earthRadius = 6_371_000.0
        let centerLatitude = center.latitude * .pi / 180
        let centerLongitude = center.longitude * .pi / 180
        let angularDistance = radius / earthRadius

        return (0 ... 96).map { index in
            let bearing = 2 * .pi * Double(index) / 96
            let latitude = asin(
                sin(centerLatitude) * cos(angularDistance) +
                    cos(centerLatitude) * sin(angularDistance) * cos(bearing)
            )
            let longitude = centerLongitude + atan2(
                sin(bearing) * sin(angularDistance) * cos(centerLatitude),
                cos(angularDistance) - sin(centerLatitude) * sin(latitude)
            )

            return CLLocationCoordinate2D(
                latitude: latitude * 180 / .pi,
                longitude: longitude * 180 / .pi
            )
        }
    }

    static func guidance(from userLocation: CLLocationCoordinate2D, to center: CLLocationCoordinate2D) -> Guidance {
        Guidance(
            bearingDegrees: bearingDegrees(from: userLocation, to: center),
            distanceMeters: distanceMeters(from: userLocation, to: center)
        )
    }

    static func relativeArrowDegrees(targetBearingDegrees: Double, phoneHeadingDegrees: Double) -> Double {
        signedDegrees(targetBearingDegrees - phoneHeadingDegrees)
    }

    static func interpolatedDegrees(from current: Double, to target: Double, factor: Double) -> Double {
        current + signedDegrees(target - current) * min(max(factor, 0), 1)
    }

    private static func distanceMeters(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude).distance(
            from: CLLocation(latitude: end.latitude, longitude: end.longitude)
        )
    }

    private static func bearingDegrees(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let startLatitude = start.latitude * .pi / 180
        let startLongitude = start.longitude * .pi / 180
        let endLatitude = end.latitude * .pi / 180
        let endLongitude = end.longitude * .pi / 180
        let deltaLongitude = endLongitude - startLongitude
        let y = sin(deltaLongitude) * cos(endLatitude)
        let x = cos(startLatitude) * sin(endLatitude) -
            sin(startLatitude) * cos(endLatitude) * cos(deltaLongitude)
        let bearing = atan2(y, x) * 180 / .pi

        return bearing >= 0 ? bearing : bearing + 360
    }

    private static func signedDegrees(_ degrees: Double) -> Double {
        let normalized = (degrees + 540).truncatingRemainder(dividingBy: 360) - 180
        return normalized == -180 ? 180 : normalized
    }
}
