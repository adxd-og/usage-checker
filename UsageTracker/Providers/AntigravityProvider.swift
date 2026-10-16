import CodexBarCore
import Foundation

/// Antigravity usage adapted from CodexBarCore (steipete/CodexBar, MIT).
///
/// Antigravity replaced the Gemini CLI OAuth path for individual Google accounts after
/// the June 2026 shutdown, so for most personal accounts this is the way to track
/// Gemini quotas. The core probe talks to the local language server of a running
/// Antigravity app / `agy` CLI / IDE extension — no external auth, no processes
/// spawned. Quotas come back as two pools (Gemini models; Claude & GPT models), each
/// with weekly and five-hour windows; a Pro plan adds per-model pools such as Argon
/// (`buckets(from:)`).
///
/// With the app closed, Antigravity's own CLI still answers: `agy -p /usage` prints the
/// quota groups the language server would, group names included. It runs in the
/// background (`AgyCommand`, `startAgyRunIfDue(now:)`), and a poll shows its last reading.
/// The same quotas also live behind Google's web API, which needs only the OAuth
/// credentials Antigravity already wrote to `~/.antigravity/oauth_creds.json`. That is the
/// last fallback, behind agy — a closed app is not a reason to tell the user nothing.
actor AntigravityProvider: UsageProvider {
    /// Singleton so the throttle caches survive across poll cycles. The one instance that
    /// runs the real agy; every other one (the tests') leaves `agyFetch` nil.
    static let shared = AntigravityProvider(agyFetch: { try await AgyCommand.fetch() })

    nonisolated let serviceID = "antigravity"

    /// The local probe and the web API, as closures: the tests inject both, so a
    /// test run never scans for a process or opens a socket.
    typealias StatusFetch = @Sendable () async throws -> AntigravityStatusSnapshot
    /// `agy -p /usage`'s stdout (`AgyCommand.fetch`). Injected like the two fetches, so no
    /// test starts agy.
    typealias AgyFetch = @Sendable () async throws -> Data

    /// Default for the settings toggle: on when Antigravity (app or CLI) is present.
    static var isAntigravityInstalled: Bool {
        let home = NSHomeDirectory()
        return FileManager.default.fileExists(atPath: "/Applications/Antigravity.app")
            || FileManager.default.fileExists(atPath: home + "/.gemini/antigravity-cli")
            || FileManager.default.fileExists(atPath: home + "/.gemini/antigravity")
    }

    private static let icon = "circle.grid.cross"

    /// Local port-scan probe is cheap, but there's no point re-probing on rapid
    /// re-polls; concurrent callers serialize on the actor. Holds the probe's own answers
    /// only (`fetch(now:)`).
    private let minFetchInterval: TimeInterval = 45
    /// The web API is a round trip to Google with a refreshable token behind it, so
    /// it runs an order of magnitude less often than the local probe.
    static let remoteMinInterval: TimeInterval = 300
    /// agy is a child process that signs in and asks Google: a run starts at most once per
    /// this interval, and only while the local probe finds nothing. The web API's five
    /// minutes less 20 s: with the five-minute poll setting (`RefreshInterval.m5`) a timer
    /// that fires a few seconds early would otherwise skip a run and double the gap.
    static let agyMinInterval: TimeInterval = remoteMinInterval - 20
    /// How old an agy reading may be and still be shown: three of the longest polls, so one
    /// failed or slow run does not drop the numbers.
    static let agyReadingMaxAge: TimeInterval = 900

    private let localFetch: StatusFetch
    private let remoteFetch: StatusFetch
    /// nil: no agy step.
    private let agyFetch: AgyFetch?

    private var cached: (snapshot: ServiceSnapshot, at: Date)?
    /// The last remote outcome, kept for `remoteMinInterval`. A nil snapshot means
    /// that attempt failed. Caching the *result* rather than just the attempt time
    /// is what stops the tile flipping back to "Not running" 45 seconds after a
    /// perfectly good web reading.
    private var remoteCache: (snapshot: ServiceSnapshot?, at: Date)?
    /// The agy run in flight: at most one, owned by this provider, never awaited by a poll.
    private var agyRun: Task<Void, Never>?
    /// When the last agy run started; the next one waits `agyMinInterval` from here.
    private var agyStartedAt: Date?
    /// The last good agy reading, stamped with the time of the poll that started its run.
    private var agyReading: ServiceSnapshot?
    /// When the local probe last answered. An agy reading older than that is never shown:
    /// it would put older numbers over newer ones the moment the app closes.
    private var localReadAt: Date?

    init(
        localFetch: @escaping StatusFetch = {
            try await AntigravityStatusProbe(processScope: .ideAndCLI).fetch()
        },
        remoteFetch: @escaping StatusFetch = {
            try await AntigravityRemoteUsageFetcher().fetch()
        },
        agyFetch: AgyFetch? = nil
    ) {
        self.localFetch = localFetch
        self.remoteFetch = remoteFetch
        self.agyFetch = agyFetch
    }

    func fetch() async -> ServiceSnapshot {
        await fetch(now: Date())
    }

    /// Injectable clock: the throttles are the behaviour worth testing. Only the local
    /// probe's answer is served from `cached` (`fetchFresh` stores it). An agy or web
    /// reading, or no reading at all, is worked out again on every poll, so a run that just
    /// finished shows at once, the fifteen-minute cap on an agy reading holds on every
    /// poll, and an app opened again is read at once; agy and the web API keep their own
    /// throttles (`agyMinInterval`, `remoteMinInterval`).
    func fetch(now: Date) async -> ServiceSnapshot {
        if let cached, now.timeIntervalSince(cached.at) < minFetchInterval {
            return cached.snapshot
        }
        return await fetchFresh(now: now)
    }

    private func fetchFresh(now: Date) async -> ServiceSnapshot {
        // Our own agy run is an agy process too: the probe (`.ideAndCLI`) would find it and
        // could wait on its endpoints or report its sign-in error. While it is in flight
        // the app counts as closed, and the poll goes straight to agy and the web API.
        if agyRun != nil {
            return await closedAppSnapshot(now: now) ?? noReading(state: .notRunning, message: nil, at: now)
        }
        do {
            let status = try await localFetch()
            let usage = try status.toUsageSnapshot()
            localReadAt = now
            let snapshot = Self.snapshot(from: usage, status: status, at: now)
            cached = (snapshot, now)
            return snapshot
        } catch {
            // The local language server is only reachable while the app/CLI/IDE is
            // up, so "not running" is the normal quiet state, not a sign-in problem.
            NSLog("[UT] Antigravity fetch failed: %@", String(describing: error))
            let isNotRunning = Self.isUnreachable(error)
            // Only that quiet state is worth asking agy, then the web API. A signed-out
            // probe or a parse failure is a different problem, and neither can fix it.
            if isNotRunning, let reading = await closedAppSnapshot(now: now) {
                return reading
            }
            return noReading(
                state: isNotRunning ? .notRunning : .error,
                message: isNotRunning ? nil : error.localizedDescription,
                at: now
            )
        }
    }

    /// A reading with the app closed: agy's last one, else the web API's. agy runs in the
    /// background (`startAgyRunIfDue`): this poll shows its last reading, never waits for
    /// one. nil when neither has a reading to show.
    private func closedAppSnapshot(now: Date) async -> ServiceSnapshot? {
        startAgyRunIfDue(now: now)
        if let fromAgy = agySnapshot(now: now) {
            return fromAgy
        }
        return await remoteSnapshot(now: now)
    }

    /// No numbers: the quiet "Antigravity isn't running" when `message` is nil, else the
    /// probe's own error.
    private func noReading(state: ServiceState, message: String?, at now: Date) -> ServiceSnapshot {
        ServiceSnapshot(
            id: serviceID,
            displayName: "Antigravity",
            icon: Self.icon,
            plan: nil,
            accountLabel: nil,
            buckets: [],
            extraUsage: nil,
            weekCost: nil,
            state: state,
            stateMessage: message ?? "Antigravity isn't running",
            fetchedAt: now
        )
    }

    /// "Not running" in the sense that matters here: nothing answered. A closed app
    /// is the obvious case, but a lingering Antigravity process with no language
    /// server behind it looks like a missing CSRF token, an undetectable port or a
    /// timeout — CodexBar's own descriptor lumps those with `.notRunning` too. None of
    /// them is the user's fault, so none earns the red chip; a signed-out CLI, an API
    /// refusal, a parse failure or an account mismatch still does.
    nonisolated static func isUnreachable(_ error: Error) -> Bool {
        if let probe = error as? AntigravityStatusProbeError {
            switch probe {
            case .notRunning, .missingCSRFToken, .portDetectionFailed, .timedOut:
                return true
            case .apiError, .parseFailed, .authenticationRequired, .accountMismatch:
                return false
            }
        }
        // The probe talks to localhost: a transport failure there ("Could not connect
        // to the server", a reset, a timeout) is a port with nobody behind it — the
        // app quit and left its pid file — never a reason to show the red chip.
        if error is URLError { return true }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return [ECONNREFUSED, ECONNRESET, ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, EPIPE].contains(Int32(nsError.code))
        }
        return false
    }

    /// Starts an agy run in the background when one is due: there is an agy step, no run is
    /// in flight, and the last one started at least `agyMinInterval` ago. The poll that
    /// starts it does not wait: the run stores its reading (`finishAgyRun`) and a later
    /// poll shows it. The child's own deadline (`AgyCommand.deadline`) ends a run that hangs.
    private func startAgyRunIfDue(now: Date) {
        guard let agyFetch, agyRun == nil else { return }
        if let agyStartedAt, now.timeIntervalSince(agyStartedAt) < Self.agyMinInterval { return }
        agyStartedAt = now
        agyRun = Task.detached(priority: .utility) { [self] in
            let result: Result<Data, Error>
            do {
                let output = try await agyFetch()
                result = .success(output)
            } catch {
                result = .failure(error)
            }
            await self.finishAgyRun(result, startedAt: now)
        }
    }

    /// A finished agy run. A good reading is stored, stamped with `startedAt`; a failure
    /// stores nothing, and the last good reading ages out. Every failure is quiet: agy
    /// missing, a locked keychain, the deadline, a failed run, a status other than SUCCESS
    /// (a signed-out agy among them), output with no row. The state chip is about the app,
    /// which is closed; a red chip for an optional CLI the user may never run would come
    /// back every five minutes.
    private func finishAgyRun(_ result: Result<Data, Error>, startedAt: Date) {
        agyRun = nil
        do {
            let report = try AgyUsageReport.parse(result.get())
            let buckets = Self.named(
                Self.buckets(from: Self.quotaSummary(from: report, at: startedAt)),
                by: Self.poolNames(from: report)
            )
            guard !buckets.isEmpty else {
                throw AgyUsageError.unreadable("no window with a known usage")
            }
            agyReading = ServiceSnapshot(
                id: serviceID,
                displayName: "Antigravity",
                icon: Self.icon,
                plan: "Antigravity",
                accountLabel: nil,
                buckets: buckets,
                extraUsage: nil,
                weekCost: nil,
                state: .ok,
                stateMessage: nil,
                fetchedAt: startedAt
            )
            NSLog("[UT] Antigravity agy fetch ok: %d window(s)", buckets.count)
        } catch {
            NSLog("[UT] Antigravity agy fetch failed: %@", String(describing: error))
        }
    }

    /// The last good agy reading while it is at most `agyReadingMaxAge` old and not older
    /// than the local probe's last answer. nil sends the poll on to the web API.
    private func agySnapshot(now: Date) -> ServiceSnapshot? {
        guard let agyReading,
              now.timeIntervalSince(agyReading.fetchedAt) <= Self.agyReadingMaxAge,
              agyReading.fetchedAt >= (localReadAt ?? .distantPast)
        else { return nil }
        return agyReading
    }

    /// Waits for the agy run in flight, if any. A poll never does; the tests do, to see a
    /// finished run's reading on their next poll without racing the run.
    func settleAgyRun() async {
        await agyRun?.value
    }

    /// The web API, at most once every `remoteMinInterval`. nil = no reading, either
    /// because the last attempt failed or because this one did; the caller then
    /// returns the plain `.notRunning` snapshot and retention keeps the numbers.
    private func remoteSnapshot(now: Date) async -> ServiceSnapshot? {
        if let remoteCache, now.timeIntervalSince(remoteCache.at) < Self.remoteMinInterval {
            return remoteCache.snapshot
        }
        do {
            let status = try await remoteFetch()
            let usage = try status.toUsageSnapshot()
            let snapshot = Self.snapshot(from: usage, status: status, at: now)
            remoteCache = (snapshot, now)
            NSLog("[UT] Antigravity remote fetch ok: %d window(s)", snapshot.buckets.count)
            return snapshot
        } catch {
            // Not signed in on the web either, or the API said no.
            NSLog("[UT] Antigravity remote fetch failed: %@", String(describing: error))
            remoteCache = (nil, now)
            return nil
        }
    }

    private static func snapshot(
        from usage: CodexBarCore.UsageSnapshot,
        status: AntigravityStatusSnapshot,
        at now: Date
    ) -> ServiceSnapshot {
        let mapped = buckets(from: usage)
        NSLog("[UT] Antigravity fetch ok: %d window(s), plan=%@", mapped.count, status.accountPlan ?? "?")
        return ServiceSnapshot(
            id: "antigravity",
            displayName: "Antigravity",
            icon: icon,
            plan: status.accountPlan.map { "Antigravity \($0.capitalized)" } ?? "Antigravity",
            accountLabel: status.accountEmail,
            buckets: mapped,
            extraUsage: nil,
            weekCost: nil,
            state: .ok,
            stateMessage: nil,
            fetchedAt: now
        )
    }

    /// The probe's reading as the app's buckets, one rule for both of its paths. Pure, so
    /// the tests hand it the `UsageSnapshot` the probe would.
    ///
    /// Quota summary (the local language server; a window id passes
    /// `AntigravityStatusSnapshot.isQuotaSummaryWindowID`): every window by itself and no
    /// aggregates. Each pool's windows are already there, and an aggregate is the worst
    /// window of its family, a per-model pool included (`summaryBucket`).
    /// Per-model (the web API, older servers): the two pool aggregates, then the model
    /// windows (`modelBuckets`).
    nonisolated static func buckets(from usage: CodexBarCore.UsageSnapshot) -> [UsageBucket] {
        let windows = usage.extraRateWindows ?? []
        let reported = windows.filter { $0.usageKnown && !$0.window.isSyntheticPlaceholder }
        if windows.contains(where: { AntigravityStatusSnapshot.isQuotaSummaryWindowID($0.id) }) {
            let labels = poolLabels(reported)
            return reported.map { summaryBucket($0, labels: labels) }
        }
        var aggregates: [UsageBucket] = []
        if let b = bucket(from: usage.primary, id: "antigravity_gemini", label: "Gemini models") {
            aggregates.append(b)
        }
        if let b = bucket(from: usage.secondary, id: "antigravity_claude_gpt", label: "Claude & GPT models") {
            aggregates.append(b)
        }
        return aggregates + modelBuckets(reported)
    }

    /// A named window as CodexBarCore reports it: its title, its kind from its length.
    private static func windowBucket(_ named: NamedRateWindow) -> UsageBucket {
        UsageBucket(
            id: "antigravity_\(named.id)",
            label: named.title,
            utilization: named.window.usedPercent,
            resetsAt: named.window.resetsAt ?? .distantFuture,
            kind: kind(for: named.window),
            windowLength: windowLength(for: named.window)
        )
    }

    /// The stems of the two pools every plan has. Any other stem is a per-model pool.
    private static let poolStems: Set<String> = [
        "gemini", // the Gemini models pool
        "3p", // the Claude and GPT models pool
    ]

    /// One quota-summary window. A pool's window keeps CodexBarCore's title and its kind
    /// from its length. Any other group is a per-model pool (Argon on Pro plans, since
    /// 2026-10-16). CodexBarCore titles every group after its family, so such a pool's
    /// weekly reads exactly like its family's own. It is named from its stem instead
    /// (`labels`, from `poolLabels`) and is `.modelSpecific`: its own row, never the
    /// headline while a pool is reported. The id stays the wire's, so History keeps the
    /// line it already has.
    private static func summaryBucket(_ named: NamedRateWindow, labels: [String: String]) -> UsageBucket {
        guard let stem = summaryStem(named.id), !poolStems.contains(stem) else {
            return windowBucket(named)
        }
        return UsageBucket(
            id: "antigravity_\(named.id)",
            label: labels[stem] ?? named.title,
            utilization: named.window.usedPercent,
            resetsAt: named.window.resetsAt ?? .distantFuture,
            kind: .modelSpecific,
            windowLength: windowLength(for: named.window)
        )
    }

    /// The probe's quota-summary window id prefix; agy's buckets take it too (`agyWindow`).
    private static let summaryWindowPrefix = "antigravity-quota-summary-"

    /// A summary window's bucket id without the cadence, lowercased and with `_` read as
    /// `-` (as CodexBarCore reads it for the cadence): `antigravity-quota-summary-3p-weekly`
    /// → `3p`. nil outside the quota summary.
    private static func summaryStem(_ id: String) -> String? {
        guard AntigravityStatusSnapshot.isQuotaSummaryWindowID(id), id.hasPrefix(summaryWindowPrefix) else { return nil }
        let stem = String(id.dropFirst(summaryWindowPrefix.count))
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard let cadence = ["-weekly", "-5h"].first(where: { stem.hasSuffix($0) }) else { return stem }
        return String(stem.dropLast(cadence.count))
    }

    /// The row name of every per-model pool in one reading, by stem. A name is the stem's
    /// words of four letters or more and words with a digit (`poolLabel`), so `…-argon-wtu`
    /// loses the wire's "wtu". Two pools in the reading that would share a name both keep
    /// every word of their stems, so neither row reads as the other. No model table: a
    /// pool that appears next month is named by the same rule. A stem with no word at all
    /// has no entry; its row keeps CodexBarCore's title, the only name left.
    private static func poolLabels(_ windows: [NamedRateWindow]) -> [String: String] {
        let stems = Set(windows.compactMap { summaryStem($0.id) }).subtracting(poolStems)
        var labels: [String: String] = [:]
        for (label, sharing) in Dictionary(grouping: stems, by: { poolLabel($0, everyWord: false) })
        where !label.isEmpty {
            for stem in sharing {
                labels[stem] = sharing.count > 1 ? poolLabel(stem, everyWord: true) : label
            }
        }
        return labels
    }

    /// A stem's words, each capitalised: only those of four letters or more and those with
    /// a digit, unless `everyWord`. When none of them passes, every word is kept
    /// (`xp-wtu` → "Xp Wtu"), never CodexBarCore's title, which names the family.
    private static func poolLabel(_ stem: String, everyWord: Bool) -> String {
        let words = stem.split(separator: "-")
        let kept = everyWord ? words : words.filter { $0.count >= 4 || $0.contains(where: \.isNumber) }
        return (kept.isEmpty ? words : kept)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// The probe's reset-only pool windows, listed when a pool's models report a reset but
    /// no usage. They and the compact fallback (the stand-in when no pool is reported)
    /// keep the plain mapping on the per-model path.
    private static let poolWindowIDs: Set<String> = [
        "antigravity-gemini", // the Gemini models pool
        "antigravity-claude-gpt", // the Claude and GPT models pool
    ]
    private static let compactFallbackPrefix = "antigravity-compact-fallback-"

    /// The row name of a model window that carries no name of its own (`modelRow`).
    private static let unnamedModelLabel = "Unnamed model"

    /// The per-model path's named windows. The probe lists a model apart only when it is
    /// in neither pool aggregate, so each is one model's limit: `.modelSpecific`, its own
    /// row, never the headline while a pool is reported. Effort variants, titles equal but
    /// for a trailing parenthesis ("… (Low)", "(Medium)", "(High)"), are one row named by
    /// the shared part, at the highest variant's percent and that variant's reset (the
    /// first listed on a tie). Windows are grouped by their row's id, so a bare title
    /// joins the variants it names and two spellings of one name are one row; the row
    /// keeps the first listed spelling, so its name holds still from poll to poll.
    private static func modelBuckets(_ windows: [NamedRateWindow]) -> [UsageBucket] {
        var rows: [UsageBucket] = []
        var rowIndex: [String: Int] = [:]
        for named in windows {
            if poolWindowIDs.contains(named.id) || named.id.hasPrefix(compactFallbackPrefix) {
                rows.append(windowBucket(named))
                continue
            }
            let row = modelRow(named)
            guard let index = rowIndex[row.id] else {
                rowIndex[row.id] = rows.count
                rows.append(row)
                continue
            }
            if row.utilization > rows[index].utilization {
                rows[index] = UsageBucket(
                    id: row.id,
                    label: rows[index].label,
                    utilization: row.utilization,
                    resetsAt: row.resetsAt,
                    kind: row.kind,
                    windowLength: row.windowLength
                )
            }
        }
        return rows
    }

    /// One model window as a row, before its variants collapse. The wire ids are
    /// placeholders, so the id comes from the name (`modelSlug`). A window with no human
    /// name, or whose name has no letter or digit (empty, blank, punctuation only), is
    /// "Unnamed model" under its own wire id and collapses with nothing.
    private static func modelRow(_ named: NamedRateWindow) -> UsageBucket {
        let stem = modelStem(named.title)
        let slug = modelSlug(stem)
        let unnamed = hasNoHumanName(named) || slug.isEmpty
        return UsageBucket(
            id: unnamed ? "antigravity_\(named.id)" : "antigravity_model-" + slug,
            label: unnamed ? unnamedModelLabel : stem,
            utilization: named.window.usedPercent,
            resetsAt: named.window.resetsAt ?? .distantFuture,
            kind: .modelSpecific,
            windowLength: windowLength(for: named.window)
        )
    }

    /// A title that is the wire id itself (any case) or says "placeholder" names no model
    /// a person would know: `MODEL_PLACEHOLDER_M419` is a codename.
    private static func hasNoHumanName(_ named: NamedRateWindow) -> Bool {
        let title = named.title.trimmingCharacters(in: .whitespaces).lowercased()
        return title == named.id.lowercased() || title.contains("placeholder")
    }

    /// A model window's title without its trailing variant, the last balanced
    /// parenthesis with any nested in it: "Argon 4 (High)" → "Argon 4",
    /// "Argon (Fast (High))" → "Argon". A title without one, or whose parentheses do not
    /// balance ("Argon (High"), is its own name.
    private static func modelStem(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")") else { return trimmed }
        var depth = 0
        var index = trimmed.endIndex
        while index > trimmed.startIndex {
            index = trimmed.index(before: index)
            if trimmed[index] == ")" {
                depth += 1
            } else if trimmed[index] == "(" {
                depth -= 1
                if depth == 0 {
                    let stem = trimmed[..<index].trimmingCharacters(in: .whitespaces)
                    return stem.isEmpty ? trimmed : stem
                }
            }
        }
        return trimmed
    }

    /// The slug of a model row's id, stable across polls: the name lowercased, each run of
    /// other characters as one `-`, so "Model 4.1 Pro" → `antigravity_model-model-4-1-pro`.
    /// Empty for a name with no letter or digit, whose row then keeps its wire id rather
    /// than a bare `antigravity_model-`.
    private static func modelSlug(_ name: String) -> String {
        var slug = ""
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
            } else if let last = slug.last, last != "-" {
                slug.append("-")
            }
        }
        if slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    private static func bucket(from window: CodexBarCore.RateWindow?, id: String, label: String) -> UsageBucket? {
        guard let w = window, !w.isSyntheticPlaceholder else { return nil }
        return UsageBucket(
            id: id,
            label: label,
            utilization: w.usedPercent,
            resetsAt: w.resetsAt ?? .distantFuture,
            kind: kind(for: w),
            windowLength: windowLength(for: w)
        )
    }

    /// Antigravity mixes five-hour and weekly pools per model group; only the
    /// reported length tells them apart for the pace indicator.
    private static func windowLength(for w: CodexBarCore.RateWindow) -> TimeInterval? {
        w.windowMinutes.map { TimeInterval($0) * 60 }
    }

    private static func kind(for w: CodexBarCore.RateWindow) -> BucketKind {
        guard let minutes = w.windowMinutes else { return .other }
        return minutes <= 24 * 60 ? .session : .weekly
    }

    // MARK: - agy /usage

    /// agy's reading as the probe's quota summary would hand it over: one window per bucket,
    /// id `antigravity-quota-summary-<bucket id>`, titled and ordered as the probe titles and
    /// orders them, its length read as the probe reads it (`agyMinutes`). `buckets(from:)`
    /// then maps it as it maps the local reading, so both paths publish the same ids, kinds
    /// and lengths and History keeps one line per window.
    nonisolated static func quotaSummary(from report: AgyUsageReport, at now: Date) -> CodexBarCore.UsageSnapshot {
        let groups = report.groups.enumerated()
            .map { (rank: familyRank($0.element.name), offset: $0.offset, group: $0.element) }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map { $0.group }
        let windows = groups.flatMap { group in
            let family = familyTitle(group.name)
            return group.buckets.enumerated()
                .map { (rank: cadenceRank(agyMinutes($0.element)), offset: $0.offset, bucket: $0.element) }
                .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
                .map { agyWindow($0.bucket, family: family) }
        }
        return CodexBarCore.UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: windows,
            updatedAt: now
        )
    }

    /// The row name of each per-model pool in an agy reading, by bucket id: its group's own
    /// name, which the probe never passes on (it titles such a group after its family). A
    /// name with no letter or digit, or one that two pools in the reading share, is left
    /// out; those rows keep the stem name `buckets(from:)` gives them.
    nonisolated static func poolNames(from report: AgyUsageReport) -> [String: String] {
        var stemsByName: [String: Set<String>] = [:]
        var candidates: [(id: String, name: String)] = []
        for group in report.groups where group.name.contains(where: { $0.isLetter || $0.isNumber }) {
            for bucket in group.buckets {
                let windowID = summaryWindowPrefix + bucket.id
                guard let stem = summaryStem(windowID), !poolStems.contains(stem) else { continue }
                stemsByName[group.name, default: []].insert(stem)
                candidates.append((id: "antigravity_" + windowID, name: group.name))
            }
        }
        var names: [String: String] = [:]
        for candidate in candidates where stemsByName[candidate.name]?.count == 1 {
            names[candidate.id] = candidate.name
        }
        return names
    }

    /// `buckets` with each per-model pool row under the name `names` holds for its id. Pool
    /// rows, and rows without an entry, are unchanged.
    nonisolated static func named(_ buckets: [UsageBucket], by names: [String: String]) -> [UsageBucket] {
        buckets.map { bucket in
            guard bucket.kind == .modelSpecific, let name = names[bucket.id] else { return bucket }
            return UsageBucket(
                id: bucket.id,
                label: name,
                utilization: bucket.utilization,
                resetsAt: bucket.resetsAt,
                kind: bucket.kind,
                windowLength: bucket.windowLength,
                credit: bucket.credit
            )
        }
    }

    /// The probe's family order: the Gemini models family first, Claude/GPT next, any other
    /// group last.
    private static func familyRank(_ group: String) -> Int {
        let name = group.lowercased()
        if name.contains("gemini") { return 0 } // the Gemini models family
        if name.contains("claude") || name.contains("gpt") { return 1 }
        return 2
    }

    /// The probe's family title: "Claude/GPT", the Gemini models family's short title, or
    /// the group's own name ("Quota" when it has none).
    private static func familyTitle(_ group: String) -> String {
        let name = group.lowercased()
        if name.contains("gemini") { return "Gemini" } // the Gemini models family's title
        if name.contains("claude") || name.contains("gpt") { return "Claude/GPT" }
        return group.isEmpty ? "Quota" : group
    }

    /// A bucket's length in minutes, read as the probe reads a quota-summary bucket's
    /// cadence (CodexBarCore's `quotaBucketKind`), so a bucket gets the same kind and length
    /// whichever path read it: its id and its name decide. agy's `window` ("5h", "weekly")
    /// decides only when neither names a cadence; the probe never sees that field. nil for
    /// any other window.
    private static func agyMinutes(_ bucket: AgyUsageReport.Bucket) -> Int? {
        cadenceMinutes([bucket.id, bucket.name]) ?? cadenceMinutes([bucket.window ?? ""])
    }

    /// The probe's names for the five-hour window; "weekly" is the week.
    private static let sessionCadenceAliases: Set<String> = ["session", "5h", "5-hour", "five hour", "five-hour"]

    /// The probe's cadence rule over `values`: each trimmed, lowercased, `_` read as `-`,
    /// and also without a trailing " limit"; a value equal to an alias, or ending in `-`
    /// and an alias, names it. A five-hour alias wins over "weekly". 300 for five hours,
    /// 10080 for the week, nil when no value names either.
    private static func cadenceMinutes(_ values: [String]) -> Int? {
        var candidates: Set<String> = []
        for value in values {
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            guard !normalized.isEmpty else { continue }
            var forms = [normalized]
            if normalized.hasSuffix(" limit") {
                forms.append(String(normalized.dropLast(" limit".count)))
            }
            for form in forms {
                candidates.insert(form)
                for alias in sessionCadenceAliases.union(["weekly"]) where form.hasSuffix("-" + alias) {
                    candidates.insert(alias)
                }
            }
        }
        if !candidates.isDisjoint(with: sessionCadenceAliases) { return 300 }
        if candidates.contains("weekly") { return 10080 }
        return nil
    }

    /// The probe's order inside a group: 5-hour, weekly, then any other window.
    private static func cadenceRank(_ minutes: Int?) -> Int {
        switch minutes {
        case 300?: return 0
        case 10080?: return 1
        default: return 2
        }
    }

    /// One agy bucket as the probe's quota-summary window: used = 100 − left. A bucket with
    /// nothing reported, or disabled, is `usageKnown: false` and becomes no row.
    private static func agyWindow(_ bucket: AgyUsageReport.Bucket, family: String) -> NamedRateWindow {
        let minutes = agyMinutes(bucket)
        let cadence: String
        switch minutes {
        case 300?: cadence = "5-hour"
        case 10080?: cadence = "weekly"
        default: cadence = bucket.name
        }
        let left = bucket.remainingFraction.map { max(0, min(100, $0 * 100)) }
        return NamedRateWindow(
            id: summaryWindowPrefix + bucket.id,
            title: family + " " + cadence,
            window: RateWindow(
                usedPercent: left.map { 100 - $0 } ?? 0,
                windowMinutes: minutes,
                resetsAt: bucket.resetTime,
                resetDescription: nil
            ),
            usageKnown: !bucket.disabled && bucket.remainingFraction != nil
        )
    }
}
