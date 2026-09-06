import Foundation

/// What the two MCP tools say in words.
///
/// A model gets the structured data as well, but the paragraph is what it will act on,
/// so it has to carry the whole decision: how full each window is, when it comes back,
/// what the dollars mean, and whether now is the moment to start something long. All
/// of it in `ResetCopy`'s spelling, so the terminal, the popover and the agent agree.
enum MCPSummary {
    // MARK: - get_usage

    static func usage(
        snapshot: StatusSnapshot, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        var sentences = snapshot.services.map {
            serviceSentence($0, now: now, calendar: calendar, locale: locale)
        }
        if sentences.isEmpty { sentences.append(StatusText.emptyLine) }
        sentences.append(advice(for: snapshot, now: now, calendar: calendar, locale: locale))
        sentences.append(stamp(snapshot, now: now, calendar: calendar, locale: locale))
        return sentences.joined(separator: " ")
    }

    /// One provider, as one sentence: `Claude (Max 5x): session 42%, resets in 1h 40m
    /// (13:00); weekly 18%, …; $4.20 today, $31.70 this week (API-equivalent, not a
    /// subscription bill).`
    static func serviceSentence(
        _ service: StatusSnapshot.Service, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        var head = service.name
        if let plan = service.plan, !plan.isEmpty { head += " (\(plan))" }

        var clauses = service.windows.map { window -> String in
            let percent = "\(window.label.lowercased()) \(Int(window.percent.rounded()))%"
            guard let at = window.resetsAt,
                  let reset = ResetCopy.both(resetsAt: at, now: now, calendar: calendar, locale: locale)
            else { return percent }
            return "\(percent), \(reset)"
        }

        var costs: [String] = []
        if let today = service.todayCost, today > 0 { costs.append(String(format: "$%.2f today", today)) }
        if let week = service.weekCost, week > 0 { costs.append(String(format: "$%.2f this week", week)) }
        if !costs.isEmpty {
            var cost = costs.joined(separator: ", ")
            // The distinction a subscription user has to hear: these dollars are what
            // the same tokens would cost at list price, not what anyone will be billed.
            if service.apiEquivalent == true { cost += " (API-equivalent, not a subscription bill)" }
            clauses.append(cost)
        }

        if service.retained,
           let at = service.retainedAt,
           let stampText = ResetCopy.absolute(resetsAt: at, now: now, calendar: calendar, locale: locale) {
            clauses.append("last known at \(stampText); the provider is not reporting now")
        }
        if clauses.isEmpty { clauses.append(StatusText.stateText(service.state).lowercased()) }
        return "\(head): \(clauses.joined(separator: "; "))."
    }

    /// The one sentence that answers "should I start this now?". Driven by the fullest
    /// window across every provider, because that is the one that will stop the work.
    static func advice(
        for snapshot: StatusSnapshot, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let worst = worstWindow(snapshot) else {
            return "No rate-limit window is reporting, so there is nothing to pace against."
        }
        let percent = Int(worst.window.percent.rounded())
        var clause = "\(worst.service.name)'s \(worst.window.label.lowercased()) window is \(percent)% used"
        if let at = worst.window.resetsAt,
           let reset = ResetCopy.both(resetsAt: at, now: now, calendar: calendar, locale: locale) {
            clause += " and \(reset)"
        }
        if percent >= 90 { return clause + " — heavy work should wait for the reset or move to a cheaper model." }
        if percent >= 75 { return clause + " — plan the next stretch of work around it." }
        return clause + ", so there is room to work."
    }

    /// The fullest window that is neither a promo pool nor model-scoped — running a
    /// bonus pool dry costs nothing, and an "Opus only" cap is not what stops the work.
    /// Promo and model-scoped windows lead only when they are all there is.
    static func worstWindow(
        _ snapshot: StatusSnapshot
    ) -> (service: StatusSnapshot.Service, window: StatusSnapshot.Window)? {
        let all = snapshot.services.flatMap { service in service.windows.map { (service, $0) } }
        let core = all.filter { !$0.1.isPromotional && $0.1.kind != "modelSpecific" }
        let pool = core.isEmpty ? all.filter { !$0.1.isPromotional } : core
        let final = pool.isEmpty ? all : pool
        guard let best = final.max(by: { $0.1.percent < $1.1.percent }) else { return nil }
        return (best.0, best.1)
    }

    /// When these numbers were true, and — past the freshness window — that they may be
    /// the last thing Omelette saw before it was closed.
    static func stamp(
        _ snapshot: StatusSnapshot, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let at = ResetCopy.absolute(resetsAt: snapshot.updatedAt, now: now, calendar: calendar, locale: locale)
            ?? "an unknown time"
        guard snapshot.isFresh(now: now) else {
            return "Numbers are from \(at) and Omelette may not be running, so treat them as the last thing it saw."
        }
        return "Numbers as of \(at)."
    }

    // MARK: - get_agents

    static func agents(
        snapshot: StatusSnapshot, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let agents = snapshot.agents
        let stampText = stamp(snapshot, now: now, calendar: calendar, locale: locale)
        guard !agents.sessions.isEmpty || agents.needsYou > 0 || agents.working > 0 else {
            return "No agent session is running. \(stampText)"
        }
        var sentences = [countPhrase(needsYou: agents.needsYou, working: agents.working)]
        for session in agents.sessions {
            let what = session.activity.map { ": \($0)" } ?? ""
            sentences.append("\(session.project) — \(stateWord(session.state))\(what).")
        }
        sentences.append(stampText)
        return sentences.joined(separator: " ")
    }

    static func countPhrase(needsYou: Int, working: Int) -> String {
        let waiting = needsYou == 1
            ? "1 session needs a decision from you"
            : "\(needsYou) sessions need a decision from you"
        let busy = working == 1 ? "1 is working" : "\(working) are working"
        return "\(waiting) and \(busy)."
    }

    static func stateWord(_ state: String) -> String {
        switch state {
        case "needsYou": return "needs you"
        case "working": return "working"
        case "done": return "done"
        default: return "idle"
        }
    }
}
