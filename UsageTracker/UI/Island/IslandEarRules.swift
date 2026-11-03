import AppKit

/// What a click on an ear does (notch-island spec 2026-10-29 § 3.6).
enum IslandEarAction: Equatable, Sendable {
    /// One agent waits: bring it forward without opening the island.
    case jump(sessionID: String)
    /// Open the island at the ear's subject: a provider's page, and a card brought into view.
    case open(subject: String?, reveal: PetCard?)
}

/// The ears as they are now (§ 3.6): nil is an ear not there.
struct IslandEars: Equatable, Sendable {
    enum LeftMark: Equatable, Sendable {
        /// The pet's 16 × 16 head.
        case head
        /// Pet off, or a head that does not fit this display's ear (`IslandEarRules.headFits`).
        case neutralDot
    }

    enum RightMark: Equatable, Sendable {
        /// The alert's number, line by line.
        case number(lines: [String])
        /// Keep awake on with the status item hidden.
        case moon
    }

    struct Ear<Mark: Equatable & Sendable>: Equatable, Sendable {
        let mark: Mark
        let action: IslandEarAction
        /// What VoiceOver reads.
        let label: String
    }

    let left: Ear<LeftMark>?
    let right: Ear<RightMark>?

    static let none = IslandEars(left: nil, right: nil)
}

/// What the ears are decided from: the app's state as it is published.
struct IslandEarInput: Equatable, Sendable {
    var mood: PetMoodInput
    var mode: PercentDisplay.Mode
    var petOn: Bool
    /// `IslandPresentationRules.Presentation.showsEars`: a notch, physical or virtual, and the ears on.
    var showsEars: Bool
    var statusItemShown: Bool
    /// The notch's height, which the ears take.
    var earHeight: CGFloat
    /// The display's backing scale: with `earHeight`, whether the head fits (`IslandEarRules.headFits`).
    var backingScale: CGFloat = 2
}

/// What each ear shows and does (§ 3.6, § 3.9). The left ear follows the top of the mood table's
/// first three rows, the right ear the alert selector, then the ☾ case. Each ear does what it shows
/// (plan OWNER 1). Pure.
enum IslandEarRules {
    /// § 3.6: at most 34.
    static let earWidth: CGFloat = 34
    /// Room each side of the number.
    static let numberInset: CGFloat = 1
    /// The dot that stands in for the head with the pet off.
    static let neutralDotSize: CGFloat = 8
    /// The number's colour on the black (prototype v9's amber; plan OWNER 5).
    static let numberToken: OMColorToken = .warning

    static func ears(_ input: IslandEarInput, now: Date, calendar: Calendar, locale: Locale) -> IslandEars {
        guard input.showsEars else { return .none }
        return IslandEars(
            left: left(input, now: now, calendar: calendar),
            right: right(input, now: now, calendar: calendar, locale: locale)
        )
    }

    /// The ears on one display (spec 2026-11-03 § Ears and hint): the same marks, actions and words on
    /// every island display, set for this display's notch, physical or virtual — the number takes
    /// one line on a pill under `IslandEarCopy.twoLineHeight` (a 24 pt menu bar), two on a taller one
    /// (the measured 30 pt external). None on a display without an island. So the displays are an input like
    /// any other (plan R18).
    static func ears(
        mood: PetMoodInput, mode: PercentDisplay.Mode, petOn: Bool, earsOn: Bool, showInMenuBar: Bool?,
        on screen: IslandScreen, now: Date, calendar: Calendar, locale: Locale
    ) -> IslandEars {
        guard let notch = screen.islandNotch else { return .none }
        let presentation = IslandPresentationRules.presentation(
            notchPresent: true, screenWidth: screen.frame.width, petOn: petOn, earsOn: earsOn
        )
        return ears(
            IslandEarInput(
                mood: mood, mode: mode, petOn: petOn, showsEars: presentation.showsEars,
                statusItemShown: StatusItemVisibilityRules.isShown(setting: showInMenuBar, islandDisplayAttached: true),
                earHeight: notch.height, backingScale: screen.backingScale
            ),
            now: now, calendar: calendar, locale: locale
        )
    }

    /// Every island display's ears, keyed by display id: what each resting pill draws. A display
    /// without an island (its menu bar hidden, or under 1280 pt) has no entry; one with nothing to
    /// say, or with the ears off, has `.none`.
    static func earsByDisplay(
        mood: PetMoodInput, mode: PercentDisplay.Mode, petOn: Bool, earsOn: Bool, showInMenuBar: Bool?,
        screens: [IslandScreen], now: Date, calendar: Calendar, locale: Locale
    ) -> [UInt32: IslandEars] {
        var byDisplay: [UInt32: IslandEars] = [:]
        for screen in screens where screen.islandNotch != nil {
            byDisplay[screen.id] = ears(
                mood: mood, mode: mode, petOn: petOn, earsOn: earsOn, showInMenuBar: showInMenuBar,
                on: screen, now: now, calendar: calendar, locale: locale
            )
        }
        return byDisplay
    }

    /// The primary island display's ears (`IslandDisplayResolver.primaryIslandScreen`); none with no
    /// island display. The one-display view of `earsByDisplay`, which § 3.6's matrix is checked through.
    static func ears(
        mood: PetMoodInput, mode: PercentDisplay.Mode, petOn: Bool, earsOn: Bool, showInMenuBar: Bool?,
        screens: [IslandScreen], now: Date, calendar: Calendar, locale: Locale
    ) -> IslandEars {
        guard let screen = IslandDisplayResolver.primaryIslandScreen(screens) else { return .none }
        return ears(
            mood: mood, mode: mode, petOn: petOn, earsOn: earsOn, showInMenuBar: showInMenuBar,
            on: screen, now: now, calendar: calendar, locale: locale
        )
    }

    private static func left(_ input: IslandEarInput, now: Date, calendar: Calendar) -> IslandEars.Ear<IslandEars.LeftMark>? {
        // The head only where its whole pixels fit the ear (spec 2026-11-03; review F2): a 24 pt pill
        // on a 1× display takes the dot, which never morphs (`IslandEarMorph.eligible`).
        let mark: IslandEars.LeftMark =
            input.petOn && headFits(earHeight: input.earHeight, backingScale: input.backingScale) ? .head : .neutralDot
        // No default: a new mood has to choose.
        switch PetMoodRules.mood(input.mood, now: now, calendar: calendar) {
        case .needsYou(let waiting):
            return IslandEars.Ear(
                mark: mark,
                action: waiting.count == 1 ? .jump(sessionID: waiting[0].id) : .open(subject: nil, reveal: .agents),
                label: IslandEarCopy.waiting(waiting)
            )
        case .claudeSignedOut(let recovery):
            return IslandEars.Ear(
                mark: mark,
                action: .open(subject: ClaudeOAuthProvider.serviceID, reveal: nil),
                label: IslandEarCopy.signedOut(recovery)
            )
        case .alert(let alert):
            return IslandEars.Ear(
                mark: mark,
                action: .open(subject: alert.serviceID, reveal: nil),
                label: IslandEarCopy.alert(alert, mode: input.mode)
            )
        case .keepAwakeNight, .working, .nothingOn, .idle:
            return nil
        }
    }

    private static func right(
        _ input: IslandEarInput, now: Date, calendar: Calendar, locale: Locale
    ) -> IslandEars.Ear<IslandEars.RightMark>? {
        if let alert = PetAlertSelector.alert(in: input.mood.services, enabledIDs: input.mood.enabledIDs) {
            return IslandEars.Ear(
                mark: .number(lines: IslandEarCopy.numberLines(alert.usedPercent, mode: input.mode, earHeight: input.earHeight)),
                action: .open(subject: alert.serviceID, reveal: nil),
                label: IslandEarCopy.alert(alert, mode: input.mode)
            )
        }
        guard let deadline = KeepAwakeRules.effectiveState(input.mood.keepAwake, now: now).deadline,
              StatusItemVisibilityRules.showsMoonEar(keepAwakeOn: true, itemShown: input.statusItemShown)
        else { return nil }
        return IslandEars.Ear(
            mark: .moon,
            action: .open(subject: nil, reveal: .keepAwake),
            label: IslandEarCopy.moon(deadline: deadline, now: now, calendar: calendar, locale: locale)
        )
    }

    /// 12 pt for up to three characters, the text floor for "100%" and two lines (plan R11).
    static func numberSize(lines: [String]) -> CGFloat {
        lines.count == 1 && lines[0].count <= 3 ? 12 : 11
    }

    /// The number's font: SF Pro Rounded (§ 3.3), semibold.
    static func numberFont(size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: .semibold)
        guard let rounded = system.fontDescriptor.withDesign(.rounded) else { return system }
        return NSFont(descriptor: rounded, size: size) ?? system
    }

    /// The head's scale in an ear: the pet's own bead, smaller only if the ear is short.
    static func headScale(earHeight: CGFloat, backingScale: CGFloat) -> PetScaleRules.Scale {
        PetScaleRules.scale(
            beads: PetContract.earSize, fitting: CGSize(width: earWidth, height: earHeight), backingScale: backingScale
        )
    }

    /// Whether the head fits an ear `earHeight` tall on a display at `backingScale` (spec 2026-11-03;
    /// review F2): its beads at whole pixels, one pixel a bead at the least, inside the ear. A 24 pt
    /// pill on a 1× display cannot hold the 26-bead head (26 pt); at 2× it is 13 pt.
    static func headFits(earHeight: CGFloat, backingScale: CGFloat) -> Bool {
        headScale(earHeight: earHeight, backingScale: backingScale).points(beads: PetContract.earSize)
            <= min(earWidth, earHeight)
    }

    /// The head centred in `ear`, on the device-pixel grid.
    static func headRect(in ear: CGRect, scale: PetScaleRules.Scale) -> CGRect {
        let side = scale.points(beads: PetContract.earSize)
        let origin = PetScaleRules.snapped(
            CGPoint(x: ear.midX - side / 2, y: ear.midY - side / 2), backingScale: scale.backingScale
        )
        return CGRect(origin: origin, size: CGSize(width: side, height: side))
    }
}
