import CoreLocation
import Foundation

/// Sunrise/sunset math for the Sun theme (auto light by day, dark by night).
/// NOAA's solar position approximation, computed on-device; accurate to a
/// couple of minutes, which is plenty for a theme switch.
enum SolarClock {
    struct DayWindow {
        let sunrise: Date
        let sunset: Date
    }

    /// True if `date` falls between local sunrise and sunset.
    static func isDaytime(at date: Date, latitude: Double, longitude: Double) -> Bool {
        guard let window = dayWindow(for: date, latitude: latitude, longitude: longitude) else {
            // Polar day/night or math edge: fall back to a plain 7-19 clock.
            let hour = Calendar.current.component(.hour, from: date)
            return (7..<19).contains(hour)
        }
        return date >= window.sunrise && date < window.sunset
    }

    /// Sunrise and sunset for the civil day containing `date`.
    static func dayWindow(for date: Date, latitude: Double, longitude: Double) -> DayWindow? {
        let calendar = Calendar.current
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let hour = Double(calendar.component(.hour, from: date))

        // NOAA: fractional year (radians).
        let gamma = 2 * Double.pi / 365 * (dayOfYear - 1 + (hour - 12) / 24)

        // Equation of time (minutes) and solar declination (radians).
        let eqTime = 229.18 * (0.000075
            + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918
            - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)

        // Hour angle for official sunrise/sunset (zenith 90.833 degrees).
        let latRad = latitude * .pi / 180
        let zenith = 90.833 * Double.pi / 180
        let cosHourAngle = cos(zenith) / (cos(latRad) * cos(decl)) - tan(latRad) * tan(decl)
        guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }
        let hourAngle = acos(cosHourAngle) * 180 / .pi

        // Minutes after 00:00 UTC.
        let sunriseUTC = 720 - 4 * (longitude + hourAngle) - eqTime
        let sunsetUTC = 720 - 4 * (longitude - hourAngle) - eqTime

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        guard let utcMidnight = utcCalendar.date(
            from: utcCalendar.dateComponents([.year, .month, .day], from: date)
        ) else { return nil }

        return DayWindow(
            sunrise: utcMidnight.addingTimeInterval(sunriseUTC * 60),
            sunset: utcMidnight.addingTimeInterval(sunsetUTC * 60)
        )
    }

    /// Coordinate estimate when the user hasn't shared location: longitude
    /// from the UTC offset (15 degrees per hour), mid-latitude guess. Sunrise
    /// lands within an hour or so, fine for a theme.
    static var estimatedCoordinate: (latitude: Double, longitude: Double) {
        let offsetHours = Double(TimeZone.current.secondsFromGMT()) / 3600
        return (latitude: 40, longitude: offsetHours * 15)
    }
}

/// One-shot location for accurate sunrise times. Optional, asked from
/// settings only (never onboarding, per the design kit); everything works
/// without it via the timezone estimate.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private let latitudeKey = "blablacadabra.solar.latitude"
    private let longitudeKey = "blablacadabra.solar.longitude"
    var onUpdate: (() -> Void)?

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    /// Saved fix if the user ever granted location, else nil.
    var savedCoordinate: (latitude: Double, longitude: Double)? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: latitudeKey) != nil else { return nil }
        return (defaults.double(forKey: latitudeKey), defaults.double(forKey: longitudeKey))
    }

    func requestFix() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        default:
            break // Denied: the timezone estimate carries the Sun theme.
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorized || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        let defaults = UserDefaults.standard
        defaults.set(fix.coordinate.latitude, forKey: latitudeKey)
        defaults.set(fix.coordinate.longitude, forKey: longitudeKey)
        onUpdate?()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix, no problem: the estimate keeps working.
    }
}
