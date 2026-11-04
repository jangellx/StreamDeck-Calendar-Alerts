import Foundation

// Today's moon, for the "Moon" no-events image. Ported from Joe Angell's
// Perpetual (SkyKit's MoonAngle) so the key shows the same frame Perpetual does.
//
// The images are thirty renderings of a month of phases (Images/moon-00 …
// moon-29, 12° apart, new moon first, full at moon-15) from NASA's Scientific
// Visualization Studio (Dial-A-Moon), made from Lunar Reconnaissance Orbiter data.
// NASA imagery isn't copyrighted; NASA asks only for credit.
enum MoonPhase {
    // The angle the moon has drawn ahead of the sun around the sky: 0° at new
    // moon, 90° at first quarter, 180° at full and 270° at last quarter. Uses the
    // short series in the Astronomical Almanac, good to a few tenths of a degree.
    static func phaseAngle(at date: Date) -> Double {
        func sine(_ degrees: Double) -> Double { sin(degrees * .pi / 180) }
        let days = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545
        let t = days / 36_525
        let moon = 218.32 + 481_267.881 * t + 6.29 * sine(135.0 + 477_198.87 * t) - 1.27 * sine(259.3 - 413_335.36 * t)
            + 0.66 * sine(235.7 + 890_534.22 * t) + 0.21 * sine(269.9 + 954_397.74 * t)
            - 0.19 * sine(357.5 + 35_999.05 * t) - 0.11 * sine(186.5 + 966_404.03 * t)
        let anomaly = 357.5291 + 0.98560028 * days
        let sun = anomaly + 1.9148 * sine(anomaly) + 0.02 * sine(2 * anomaly) + 180 + 102.9372
        let angle = (moon - sun).truncatingRemainder(dividingBy: 360)
        return angle < 0 ? angle + 360 : angle
    }

    // The image name for a day's moon (moon-00 … moon-29), taken at local noon so
    // the whole day shows one frame, as Perpetual does.
    static func imageName(onDayOf day: Date) -> String {
        let angle = phaseAngle(at: Calendar.current.startOfDay(for: day) + 12 * 3600)
        return String(format: "moon-%02d", Int((angle / 12).rounded()) % 30)
    }
}
