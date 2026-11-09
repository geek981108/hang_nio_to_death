import Foundation

enum VehicleDateParser {
    static func displayDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%02d/%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeSeconds = ISO8601DateFormatter()

    static func parse(_ value: String) -> Date? {
        // Decoding runs concurrently. Reuse formatters without allowing
        // simultaneous access to their mutable Foundation internals.
        lock.lock()
        defer { lock.unlock() }
        if let date = fractional.date(from: value) { return date }
        return wholeSeconds.date(from: value)
    }
}
