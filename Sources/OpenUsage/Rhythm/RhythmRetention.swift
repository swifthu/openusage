import Foundation

/// How long the rhythm history is kept.
///
/// The constant lives here, and not in the settings, so that it is not tied to a `@MainActor`
/// class: the file store's default argument is evaluated in the caller's context, so a constant
/// that sits on an actor-isolated class needs a workaround to be read from there.
enum RhythmRetention {
    /// How many days of history are kept. The store trims the days that are older than this.
    static let retentionDays = 90
}
