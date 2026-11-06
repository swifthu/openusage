import Foundation

/// A rhythm history that cannot be read.
enum RhythmStoreError: LocalizedError {
    case unknownSchema(String)

    var errorDescription: String? {
        switch self {
        case .unknownSchema(let schema):
            "The rhythm history uses an unknown format (\(schema))."
        }
    }
}

/// Where the rhythm history lives. The local file store is today's implementation; a cloud store
/// that puts the same records elsewhere can be added without touching the recorder or the chart.
protocol RhythmStore: Sendable {
    /// Writes a day's record, replacing what was there.
    func save(_ record: RhythmDayRecord) throws
    /// The record of a day, nil when nothing was recorded for it.
    func load(day: Date) throws -> RhythmDayRecord?
    /// The records of a range of days, oldest first.
    func load(days: ClosedRange<Date>) throws -> [RhythmDayRecord]
    /// The days that have a record, oldest first. A history that does not exist yet is empty; a
    /// history that cannot be read is an error.
    func recordedDays() throws -> [Date]
    /// Deletes the records before a date. The date names a day, so it is compared as one: a cutoff
    /// in the afternoon leaves that day's own record alone.
    func delete(before date: Date) throws
}

extension RhythmStore {
    /// Removes every recorded day, today's own record included.
    ///
    /// The store deletes the days *before* the cutoff, so the cutoff has to be tomorrow's
    /// midnight to take today's record with it.
    func deleteAll(now: Date = Date(), calendar: Calendar = .current) throws {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        try delete(before: tomorrow)
    }
}

/// The rhythm history as one file per day under Application Support.
struct FileRhythmStore: RhythmStore {
    /// The folder the day files live in.
    let directory: URL
    /// The calendar the days are measured in. It decides which file a moment belongs to, so it has
    /// to be the same one the recorder writes with.
    let calendar: Calendar
    /// How many days of history are kept. The days older than that are removed when a day is
    /// written, so the history does not grow without end.
    let retentionDays: Int

    init(directory: URL = FileRhythmStore.defaultDirectory, calendar: Calendar, retentionDays: Int = RhythmRetention.retentionDays) {
        self.directory = directory
        self.calendar = calendar
        self.retentionDays = retentionDays
    }

    static var defaultDirectory: URL {
        directory(forBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func directory(forBundleIdentifier identifier: String?) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("OpenUsage", isDirectory: true)
            .appendingPathComponent("rhythm", isDirectory: true)
            // The app is not sandboxed, so Application Support is shared by every build of it.
            // The bundle identifier keeps the development build and the installed one apart.
            .appendingPathComponent(identifier ?? "default", isDirectory: true)
    }

    private struct Payload: Codable {
        var schema: String
        var series: [RhythmSeriesRecord]
    }

    func save(_ record: RhythmDayRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Payload(schema: RhythmDayRecord.currentSchema, series: record.series)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: url(for: record.day), options: .atomic)
        trimOldDays(around: record.day)
    }

    /// Removes the days that are older than the retention length, so the history does not grow
    /// without end. The days are counted from today and not from the day that was just written:
    /// the retention is a promise about today, so a clock that was set forward must not delete a
    /// history that is still inside the window.
    ///
    /// A day that cannot be removed is left in place and warned about: the history that is there
    /// is better than a history that is gone.
    private func trimOldDays(around day: Date) {
        // A day that was written is normally today, but it can be in the past (a day the app
        // writes after the clock was turned back) or in the future (a clock that was set
        // forward). The cutoff follows the earlier of the two, so the future never pulls it up.
        let today = calendar.startOfDay(for: min(day, Date()))
        guard let cutoffDate = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today) else { return }
        // Adding a day to a midnight that falls on a daylight-saving transition gives 01:00 and
        // not 00:00, which would take the boundary day with it and lose a day for nothing.
        let cutoff = calendar.startOfDay(for: cutoffDate)
        let days: [Date]
        do {
            days = try recordedDays()
        } catch {
            AppLog.warn(.rhythm, "could not list the rhythm history to trim it: \(error.localizedDescription)")
            return
        }
        for old in days where old < cutoff {
            do {
                try FileManager.default.removeItem(at: url(for: old))
            } catch {
                AppLog.warn(.rhythm, "could not remove the rhythm history of \(RhythmClock.fileName(for: old, calendar: calendar)): \(error.localizedDescription)")
            }
        }
    }

    func load(day: Date) throws -> RhythmDayRecord? {
        let file = url(for: day)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: file))
        guard payload.schema == RhythmDayRecord.currentSchema else {
            throw RhythmStoreError.unknownSchema(payload.schema)
        }
        return RhythmDayRecord(day: calendar.startOfDay(for: day), series: payload.series)
    }

    /// A day that cannot be read is skipped: one broken file must not take the whole range with it.
    func load(days: ClosedRange<Date>) throws -> [RhythmDayRecord] {
        // The range names days, so it is compared as days: a range that starts in the afternoon
        // still includes the record of that same day.
        let firstDay = calendar.startOfDay(for: days.lowerBound)
        let lastDay = calendar.startOfDay(for: days.upperBound)
        return try recordedDays()
            .filter { $0 >= firstDay && $0 <= lastDay }
            .compactMap { day in
                do {
                    return try load(day: day)
                } catch {
                    AppLog.warn(.rhythm, "Skipping the unreadable rhythm day file \(RhythmClock.fileName(for: day, calendar: calendar)): \(error.localizedDescription)")
                    return nil
                }
            }
    }

    func recordedDays() throws -> [Date] {
        // A folder that was never created means the app has no history yet, which is not a problem.
        // A folder that exists but cannot be read is a problem the user has to know about, so it is
        // thrown instead of being read as an empty history.
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .compactMap { RhythmClock.day(fromFileName: $0, calendar: calendar) }
            .sorted()
    }

    func delete(before date: Date) throws {
        // The cutoff names a day, so it is compared as days: a cutoff in the afternoon does not
        // take the record of that same day with it.
        let cutoff = calendar.startOfDay(for: date)
        for day in try recordedDays() where day < cutoff {
            try FileManager.default.removeItem(at: url(for: day))
        }
    }

    private func url(for day: Date) -> URL {
        directory.appendingPathComponent(RhythmClock.fileName(for: day, calendar: calendar))
    }
}
