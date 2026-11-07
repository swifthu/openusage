import Foundation

/// The five-minute grid the rhythm history sits on. The bucket count follows the local calendar,
/// so a day that loses an hour to daylight saving has fewer buckets and one that gains an hour has
/// more. The bucket an instant falls in is measured in real seconds from the day's midnight, so
/// the hour a day repeats is recorded twice rather than merged.
enum RhythmClock {
    /// The length of one bucket, in seconds.
    static let bucketSeconds: TimeInterval = 5 * 60

    /// How many buckets the day has.
    static func bucketCount(on day: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return Int((end.timeIntervalSince(start) / bucketSeconds).rounded())
    }

    /// The bucket an instant falls in, nil when it is outside the day.
    static func bucketIndex(for date: Date, on day: Date, calendar: Calendar = .current) -> Int? {
        let start = calendar.startOfDay(for: day)
        let offset = date.timeIntervalSince(start)
        let count = bucketCount(on: day, calendar: calendar)
        guard offset >= 0, offset < Double(count) * bucketSeconds else { return nil }
        return Int(offset / bucketSeconds)
    }

    /// The start of a bucket.
    static func start(of index: Int, on day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(
            byAdding: .second,
            value: index * Int(bucketSeconds),
            to: calendar.startOfDay(for: day)
        ) ?? day
    }

    /// The buckets an interval touches, and the share of it that falls in each.
    ///
    /// An interval that ends exactly on the next midnight still belongs to the day it started in:
    /// its last instant is that day's last bucket, and dropping it would lose the share the day
    /// burned in its final minutes.
    ///
    /// The shares cover only the part of the interval that falls inside `day`. A share is a
    /// fraction of the **whole** interval, so the shares of the two days an interval crosses sum
    /// to one: the part that fell in the next day is in no bucket of the day it was asked about,
    /// and the part that fell in the day before is in no bucket of the day it was asked about
    /// either. The caller is expected to ask about both days, or to lose the consumption that
    /// crossed the boundary.
    static func shares(
        from start: Date,
        to end: Date,
        day: Date,
        calendar: Calendar = .current
    ) -> [RhythmBucketShare] {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return [] }

        let count = bucketCount(on: day, calendar: calendar)
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(Double(count) * bucketSeconds)
        let clampedEnd = min(end, dayEnd)

        let first: Int
        if let index = bucketIndex(for: start, on: day, calendar: calendar) {
            first = index
        } else if start < dayStart {
            // The interval began before this day, so the part of it that falls in this day starts
            // at the day's first bucket.
            first = 0
        } else {
            return []
        }
        let last: Int
        if let index = bucketIndex(for: clampedEnd, on: day, calendar: calendar) {
            last = index
        } else {
            // The end landed exactly on the day's boundary, so it is the day's last bucket.
            last = count - 1
        }
        guard last >= first else { return [] }

        var result: [RhythmBucketShare] = []
        for index in first...last {
            let bucketStart = self.start(of: index, on: day, calendar: calendar)
            let bucketEnd = bucketStart.addingTimeInterval(bucketSeconds)
            let overlap = min(bucketEnd, clampedEnd).timeIntervalSince(max(bucketStart, start))
            guard overlap > 0 else { continue }
            result.append(RhythmBucketShare(index: index, share: overlap / total))
        }
        return result
    }

    /// The key a day's file carries, "yyyy-MM-dd".
    ///
    /// The key is built from the calendar's own parts rather than from a formatter, so it is the
    /// same in every time zone the calendar names and no formatter has to be kept alive: the tab
    /// reads up to ninety of these names every thirty seconds.
    static func dayKey(for day: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let dayNumber = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, dayNumber)
    }

    /// The name a day's file carries.
    static func fileName(for day: Date, calendar: Calendar = .current) -> String {
        dayKey(for: day, calendar: calendar) + ".json"
    }

    /// The day a file name carries, nil when the name is not one of ours.
    static func day(fromFileName name: String, calendar: Calendar = .current) -> Date? {
        guard name.hasSuffix(".json") else { return nil }
        let parts = String(name.dropLast(5)).split(separator: "-")
        guard parts.count == 3 else { return nil }
        guard let year = Int(parts[0]), let month = Int(parts[1]), let dayNumber = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayNumber
        guard let date = calendar.date(from: components) else { return nil }
        // A day that does not exist — the thirteenth of a month — is rolled over by the calendar
        // instead of refused, so the name is checked against the day it names.
        let named = calendar.dateComponents([.year, .month, .day], from: date)
        guard named.year == year, named.month == month, named.day == dayNumber else { return nil }
        return calendar.startOfDay(for: date)
    }
}
