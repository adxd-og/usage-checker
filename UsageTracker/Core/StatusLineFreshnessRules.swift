import Foundation

/// Which of Claude Code's status-line readings carry new numbers (spec 2026-11-02 Claude
/// limits from the status line, § Design › App, the freshness state machine).
///
/// A drop file says when the CLI wrote it, not when Claude Code got the numbers: Claude
/// Code re-runs the line every minute, on a permission or vim change and when a reset
/// passes, always with the data it last received. So a reading's age is known only from
/// the moment the session's API time grows — `total_api_duration_ms` moves only after an
/// API response — and one seen for the first time has no known age at all. `prompt_id`
/// is carried but never dates a reading: it may move when a prompt is submitted, before
/// the API answers, with the previous answer's limits still in the payload (session
/// ruling 2026-11-02). Per session, keyed by its id:
///
/// 1. First sight (after a launch, or a new session): the counters are kept, `asOf` is
///    nil, and the reading is never applied.
/// 2. The API time grew: `asOf` is that file's `written_at`.
/// 3. The API time did not change: `asOf` stays. (Less than before is a counter that
///    started over — a resumed process — and counts as first sight.)
/// 4. A window whose reset has passed is no window (`liveWindow`).
/// 5. Ten minutes with no new file: the session is gone (`isEvicted`). v1 has no
///    `SessionEnd` path; age alone ends a session.
///
/// A reading without `total_api_duration_ms` can never be seen to grow, so it is never
/// dated.
enum StatusLineFreshnessRules {
    /// One session as the app keeps it between loads of the folder.
    struct Session: Equatable, Sendable {
        let sessionID: String
        /// Carried for the record; never compared (see above).
        let promptID: String?
        let totalAPIDurationMs: Double?
        /// When these numbers were new: the `written_at` of the file in which the API time
        /// last grew. nil while that is unknown — first sight, a restarted counter, no
        /// API time.
        let asOf: Date?
        /// The newest file's `written_at`: what eviction measures.
        let writtenAt: Date
        let fiveHour: StatusLineInput.RateLimits.Window?
        let sevenDay: StatusLineInput.RateLimits.Window?
        /// The Claude Code configuration folder the session ran under.
        let configDir: String
    }

    /// Step 5: a session whose newest file is older than this is gone. Claude Code re-runs
    /// the line every minute (`StatusLineInstaller`'s `refreshInterval`), so ten minutes of
    /// silence is a session that ended or a Mac that slept.
    static let evictionAge: TimeInterval = 600

    /// Steps 1–3: the session after one file. A file older than the newest one already
    /// seen — two runs of the line renaming out of order — changes nothing.
    static func advance(_ known: Session?, with reading: StatusLineDrop.Reading) -> Session {
        if let known, reading.writtenAt < known.writtenAt { return known }
        let asOf: Date?
        if let apiTime = reading.totalAPIDurationMs,
           let known,
           let knownAPITime = known.totalAPIDurationMs {
            if apiTime > knownAPITime {
                asOf = reading.writtenAt
            } else if apiTime == knownAPITime {
                asOf = known.asOf
            } else {
                asOf = nil
            }
        } else {
            asOf = nil
        }
        return Session(
            sessionID: reading.sessionID,
            promptID: reading.promptID,
            totalAPIDurationMs: reading.totalAPIDurationMs,
            asOf: asOf,
            writtenAt: reading.writtenAt,
            fiveHour: reading.fiveHour,
            sevenDay: reading.sevenDay,
            configDir: reading.configDir
        )
    }

    /// Step 5.
    static func isEvicted(_ session: Session, now: Date) -> Bool {
        now.timeIntervalSince(session.writtenAt) > evictionAge
    }

    /// The table after one load of the folder: every reading advanced against what was
    /// known of its session, then every session evicted whose newest file is too old. A
    /// session whose file is gone is gone with it.
    static func table(
        _ known: [String: Session], readings: [StatusLineDrop.Reading], now: Date
    ) -> [String: Session] {
        var next: [String: Session] = [:]
        for reading in readings {
            next[reading.sessionID] = advance(next[reading.sessionID] ?? known[reading.sessionID], with: reading)
        }
        return next.filter { !isEvicted($0.value, now: now) }
    }

    /// Step 4: a window whose reset has passed has started over; the number it carries is
    /// from before.
    static func liveWindow(
        _ window: StatusLineInput.RateLimits.Window?, now: Date
    ) -> StatusLineInput.RateLimits.Window? {
        guard let window, window.resetsAt > now else { return nil }
        return window
    }
}
