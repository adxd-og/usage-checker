import AppKit
import XCTest
@testable import Omelette

/// Tester's verification of P6 (notch-island spec 2026-10-29 § 3.1 Notch hint, D13, § 3.5 Roster and
/// Alert selector, § 3.6, § 3.7, § 3.9). The rules, against an oracle written from the spec's words and
/// not from the code: every combination of what the ears are decided from, the stored pet's
/// resolution, the open that an ear asks for, and the agents card of each provider set.
final class P6VerificationEarMatrixTests: XCTestCase {
    private let now = PetRuntimeFixture.t0
    private let locale = Locale(identifier: "en_GB")
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // MARK: Scenarios

    private enum Agents: CaseIterable { case none, working, one, two }
    private enum Limits: CaseIterable {
        case none, claude40, claudeWeek92, codex95, claudeSignedOut, signedOutAndCodex95, claude90Exactly, claude137
    }
    private enum Awake: CaseIterable { case idle, armed, armedPast, ended }
    private enum Display: CaseIterable { case none, externalOnly, builtIn, externalAndBuiltIn, narrowNotched }

    private func sessions(_ agents: Agents) -> [AgentSession] {
        switch agents {
        case .none: return []
        case .working: return [Fixture.agentSession(sessionID: "w", state: .working)]
        case .one: return [Fixture.agentSession(sessionID: "a", state: .needsYou)]
        case .two:
            return [
                Fixture.agentSession(sessionID: "a", state: .needsYou, lastEventAt: now),
                Fixture.agentSession(sessionID: "b", projectName: "Other", state: .needsYou, lastEventAt: now - 5),
            ]
        }
    }

    private func claude(_ percent: Double) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "seven_day", label: "All models", percent: percent, kind: .weekly),
        ], at: now)
    }

    private func codex(_ percent: Double) -> ServiceSnapshot {
        Fixture.snapshot(id: "codex", displayName: "Codex", buckets: [
            Fixture.bucket(id: "weekly", label: "Weekly", percent: percent, kind: .weekly),
        ], at: now)
    }

    private func services(_ limits: Limits) -> [ServiceSnapshot] {
        switch limits {
        case .none: return []
        case .claude40: return [claude(40)]
        case .claudeWeek92: return [claude(92)]
        case .codex95: return [codex(95)]
        case .claudeSignedOut: return [ServiceSnapshot.notSignedIn(reason: .notFound, message: "Signed out.", at: now)]
        case .signedOutAndCodex95:
            return [ServiceSnapshot.notSignedIn(reason: .notFound, message: "Signed out.", at: now), codex(95)]
        case .claude90Exactly: return [claude(90)]
        case .claude137: return [claude(137)]
        }
    }

    /// The alert the spec's selector fires for, if any: (provider id, name, used percent).
    private func alert(_ limits: Limits) -> (id: String, name: String, used: Double)? {
        switch limits {
        case .none, .claude40, .claudeSignedOut: return nil
        case .claudeWeek92: return ("claude", "Claude", 92)
        case .codex95, .signedOutAndCodex95: return ("codex", "Codex", 95)
        case .claude90Exactly: return ("claude", "Claude", 90)
        case .claude137: return ("claude", "Claude", 100)
        }
    }

    private func keepAwake(_ awake: Awake) -> KeepAwakeState {
        switch awake {
        case .idle: return .idle
        case .armed: return .armed(deadline: now + 3_600, floorEnabled: true)
        case .armedPast: return .armed(deadline: now - 1, floorEnabled: true)
        case .ended: return .ended(at: now - 60, reason: .deadline)
        }
    }

    private func screens(_ display: Display) -> [IslandScreen] {
        switch display {
        case .none: return []
        case .externalOnly: return [ScreenFixture.externalRight]
        case .builtIn: return [ScreenFixture.builtIn]
        case .externalAndBuiltIn: return [ScreenFixture.externalRight, ScreenFixture.builtIn]
        case .narrowNotched: return [ScreenFixture.narrowNotched]
        }
    }

    private func spokenNumber(_ used: Double, _ mode: PercentDisplay.Mode) -> String {
        let value = mode == .remaining ? 100 - min(used, 100) : min(used, 100)
        return "\(Int(value.rounded())) percent \(mode == .remaining ? "left" : "used")"
    }

    // MARK: The matrix

    /// Every mood, Remaining mode, pet on or off, ears on or off, status item shown or hidden, screens
    /// with and without a notch, keep awake armed or not: 15 360 readings, each checked against § 3.6.
    func testEveryCombinationOfWhatTheEarsAreDecidedFromAgreesWithSection36() {
        var checked = 0
        for agents in Agents.allCases {
            for limits in Limits.allCases {
                for awake in Awake.allCases {
                    for display in Display.allCases {
                        for mode in [PercentDisplay.Mode.used, .remaining] {
                            for petOn in [true, false] {
                                for earsOn in [true, false] {
                                    for item in [Optional<Bool>.none, true, false] {
                                        verify(agents, limits, awake, display, mode, petOn, earsOn, item)
                                        checked += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 15_360)
    }

    // swiftlint:disable:next function_parameter_count
    private func verify(
        _ agents: Agents, _ limits: Limits, _ awake: Awake, _ display: Display,
        _ mode: PercentDisplay.Mode, _ petOn: Bool, _ earsOn: Bool, _ item: Bool?
    ) {
        let context = "\(agents) \(limits) \(awake) \(display) \(mode) pet:\(petOn) ears:\(earsOn) item:\(String(describing: item))"
        let ears = IslandEarRules.ears(
            mood: PetMoodInput(
                sessions: sessions(agents), services: services(limits), enabledIDs: ["claude", "codex"],
                claudeBinaryFound: true, keepAwake: keepAwake(awake)
            ),
            mode: mode, petOn: petOn, earsOn: earsOn, showInMenuBar: item,
            screens: screens(display), now: now, calendar: utc, locale: locale
        )
        let notched = display == .builtIn || display == .externalAndBuiltIn || display == .narrowNotched

        // An ear is never there without a notch, nor with the ears off.
        guard notched, earsOn else {
            XCTAssertEqual(ears, IslandEars.none, context)
            return
        }

        // The status item: the setting wins; unset, a notched Mac hides it (§ 3.7).
        let itemShown = item ?? false
        let waiting = sessions(agents).filter { $0.state == .needsYou }
        let alert = self.alert(limits)

        // Left ear (§ 3.5 rows 1-3).
        let leftMark: IslandEars.LeftMark = petOn ? .head : .neutralDot
        if waiting.count == 1 {
            XCTAssertEqual(ears.left?.mark, leftMark, context)
            XCTAssertEqual(ears.left?.action, .jump(sessionID: waiting[0].id), context)
        } else if waiting.count > 1 {
            XCTAssertEqual(ears.left?.mark, leftMark, context)
            XCTAssertEqual(ears.left?.action, .open(subject: nil, reveal: .agents), context)
        } else if limits == .claudeSignedOut || limits == .signedOutAndCodex95 {
            XCTAssertEqual(ears.left?.mark, leftMark, context)
            XCTAssertEqual(ears.left?.action, .open(subject: "claude", reveal: nil), context)
        } else if let alert {
            XCTAssertEqual(ears.left?.mark, leftMark, context)
            XCTAssertEqual(ears.left?.action, .open(subject: alert.id, reveal: nil), context)
            XCTAssertTrue(ears.left?.label.contains(spokenNumber(alert.used, mode)) == true, context)
            XCTAssertTrue(ears.left?.label.hasPrefix(alert.name) == true, context)
        } else {
            XCTAssertNil(ears.left, "a working agent, a night or a quiet limit needs no head: \(context)")
        }

        // Right ear: the alert's number in the asked mode, else ☾, else nothing (§ 3.6).
        if let alert {
            let number = PercentDisplay.percentText(alert.used, mode: mode)
            let expected: [String] = mode == .remaining ? [number, "left"] : [number]
            XCTAssertEqual(ears.right?.mark, .number(lines: expected), context)
            XCTAssertEqual(ears.right?.action, .open(subject: alert.id, reveal: nil), context)
            XCTAssertTrue(ears.right?.label.contains(spokenNumber(alert.used, mode)) == true, context)
        } else if awake == .armed, !itemShown {
            XCTAssertEqual(ears.right?.mark, .moon, context)
            XCTAssertEqual(ears.right?.action, .open(subject: nil, reveal: .keepAwake), context)
        } else {
            XCTAssertNil(ears.right, context)
        }

        // Whatever is shown can be heard.
        for label in [ears.left?.label, ears.right?.label].compactMap({ $0 }) {
            XCTAssertFalse(label.isEmpty, context)
        }
    }

    // MARK: Hostile numbers

    /// A spend limit reads 137 %: no ear may print more than 100 or less than 0, in either mode.
    func testAnOverrunLimitPrintsAtMost100AndRemainingNeverGoesBelowZero() {
        for used in [90.0, 99.4, 100, 104, 137, 10_000] {
            XCTAssertEqual(IslandEarCopy.numberLines(used, mode: .used, earHeight: 32), ["\(min(Int(used.rounded()), 100))%"], "\(used)")
            XCTAssertEqual(
                IslandEarCopy.numberLines(used, mode: .remaining, earHeight: 32),
                ["\(100 - min(Int(used.rounded()), 100))%", "left"], "\(used)"
            )
        }
    }

    /// The two-line threshold is the line height twice: 28 pt gets two lines, 27.9 keeps the number.
    func testTheTwoLineThresholdIsExactlyTwoLinesOfTheTextFloor() {
        XCTAssertEqual(IslandEarCopy.numberLines(92, mode: .remaining, earHeight: 28), ["8%", "left"])
        XCTAssertEqual(IslandEarCopy.numberLines(92, mode: .remaining, earHeight: 27.9), ["8%"])
        XCTAssertEqual(IslandEarCopy.numberLines(92, mode: .used, earHeight: 40), ["92%"], "used mode never needs the word")
    }

    /// The head sits on the device-pixel grid inside the ear for every notch height and backing scale.
    func testTheHeadIsAlwaysInsideItsEarAndOnWholeDevicePixels() {
        for backing in [1.0, 2.0, 3.0] as [CGFloat] {
            for height in stride(from: 26.0, through: 44.0, by: 0.5) as StrideThrough<CGFloat> {
                let scale = IslandEarRules.headScale(earHeight: height, backingScale: backing)
                let ear = CGRect(x: 100.5, y: 0, width: IslandEarRules.earWidth, height: height)
                let rect = IslandEarRules.headRect(in: ear, scale: scale)
                XCTAssertGreaterThanOrEqual(rect.minX, ear.minX - 0.001, "h \(height) @\(backing)")
                XCTAssertLessThanOrEqual(rect.maxX, ear.maxX + 0.001, "h \(height) @\(backing)")
                XCTAssertGreaterThanOrEqual(rect.minY, ear.minY - 0.001, "h \(height) @\(backing)")
                XCTAssertLessThanOrEqual(rect.maxY, ear.maxY + 0.001, "h \(height) @\(backing)")
                XCTAssertEqual((rect.minX * backing).rounded(), rect.minX * backing, accuracy: 0.0001, "x on the pixel grid")
                XCTAssertEqual((rect.minY * backing).rounded(), rect.minY * backing, accuracy: 0.0001, "y on the pixel grid")
            }
        }
    }
}

/// § 3.5 Roster, F5 of the P5d tester: the pair that is drawn always exists in the library, whatever the
/// defaults hold, and nothing is written back.
final class P6VerificationPetChoiceTests: XCTestCase {
    private static let shipped = PetLibrary.bundled()
    private var directory: URL!
    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P6VerificationPetChoiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        AppDomainRestore.restore(savedDomain, domainName: domainName)
    }

    private func library(_ folders: [String]) throws -> PetLibrary {
        for folder in folders {
            try PetFixture.write(
                PetFixture.setting(["id"], to: folder, in: PetFixture.manifest()), folder: folder, in: directory
            )
        }
        return PetLibrary.load(from: directory)
    }

    private func exists(_ choice: PetChoice, in library: PetLibrary) -> Bool {
        library.manifests[choice.animal]?.palettes[choice.palette] != nil
    }

    func testHostileStoredPairsAlwaysResolveToAPetThatExistsAndNeverAgainChange() throws {
        let hostile = [
            "", " ", "cat ", " cat", "CAT", "Cat", "cat\n", "ca\u{0}t", "../cat", "cat/ginger", "🐱", "é", "dog,tan",
            String(repeating: "x", count: 100_000), "__proto__", "null", "0",
        ]
        // Every real palette name of every animal, so that a name another animal has is tried on each.
        let palettes = hostile + ["ginger", "cream", "tuxedo", "yellow", "white", "mallard", "tan", "black-white", "grey", "brown", "silver", "GINGER", "black_white"]
        for animal in hostile + ["cat", "duck", "dog", "raccoon"] {
            for palette in palettes {
                let stored = PetChoice(animal: animal, palette: palette)
                let resolved = try XCTUnwrap(PetChoiceRules.resolved(stored, in: Self.shipped), "\(animal)/\(palette)".prefix(40).description)
                XCTAssertTrue(exists(resolved, in: Self.shipped), "\(animal)/\(palette)".prefix(40).description)
                XCTAssertEqual(PetChoiceRules.resolved(resolved, in: Self.shipped), resolved, "a drawn pair is a fixed point")
                if exists(stored, in: Self.shipped) { XCTAssertEqual(resolved, stored) }
                if Self.shipped.manifests[animal] != nil {
                    XCTAssertEqual(resolved.animal, animal, "a known animal is never swapped for a bad palette")
                } else {
                    XCTAssertEqual(resolved, PetChoice.standard, "an unknown animal gives the cat in ginger, never the old palette's name")
                }
            }
        }
    }

    /// The roster's order picks the fallback animal, not the library's dictionary order.
    func testWithoutTheCatTheRostersOrderChoosesTheNextAnimal() throws {
        let library = try library(["raccoon", "dog", "duck", "zebra"])
        XCTAssertEqual(
            PetChoiceRules.resolved(PetChoice(animal: "otter", palette: "x"), in: library),
            PetChoice(animal: "duck", palette: "white"),
            "cat, duck, dog, raccoon: the duck comes first of the animals left, in the table's first palette it has"
        )
        XCTAssertEqual(
            PetChoiceRules.resolved(PetChoice(animal: "dog", palette: "pink"), in: library),
            PetChoice(animal: "dog", palette: "grey"),
            "the stored animal keeps its place"
        )
    }

    /// The stale pair stays in the defaults: nothing that draws writes it back, so a returning pack
    /// brings the choice with it.
    @MainActor
    func testResolvingAStalePairWritesNothingBackAndReadsBackAsStored() throws {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        settings.petChoice = PetChoice(animal: "otter", palette: "pink")
        let model = IslandPetModel(keeper: PetKeeper(random: PetRandom { 0 }), clock: { PetRuntimeFixture.t0 }, choice: settings.petChoice)
        XCTAssertEqual(model.shown(in: Self.shipped), PetChoice.standard)
        XCTAssertNotNil(PetChoiceRules.resolved(settings.petChoice, in: Self.shipped))
        XCTAssertEqual(settings.petChoice, PetChoice(animal: "otter", palette: "pink"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsStore.petAnimalKey), "otter")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsStore.petPaletteKey), "pink")
        XCTAssertEqual(
            SettingsStore.storedPetChoice(
                animal: UserDefaults.standard.string(forKey: SettingsStore.petAnimalKey),
                palette: UserDefaults.standard.string(forKey: SettingsStore.petPaletteKey)
            ),
            PetChoice(animal: "otter", palette: "pink")
        )
    }

    @MainActor
    func testResetPutsTheStandardPetBackAndForgetsTheKeysAndTheSwitches() {
        let settings = SettingsStore.shared
        settings.petChoice = PetChoice(animal: "raccoon", palette: "silver")
        settings.petEnabled = false
        settings.earsEnabled = false
        settings.resetToDefaults()
        XCTAssertEqual(settings.petChoice, PetChoice.standard)
        XCTAssertTrue(settings.petEnabled)
        XCTAssertTrue(settings.earsEnabled)
        for key in [SettingsStore.petAnimalKey, SettingsStore.petPaletteKey, SettingsStore.petEnabledKey, SettingsStore.earsEnabledKey] {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), key)
        }
    }

    /// Switching the pet off and the ears off are independent keys: one does not write the other.
    @MainActor
    func testTheSwitchesAndTheChoiceAreIndependentKeys() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        settings.petChoice = PetChoice(animal: "duck", palette: "white")
        settings.earsEnabled = false
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.petEnabledKey))
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsStore.petAnimalKey), "duck")
        settings.petEnabled = false
        settings.petEnabled = true
        XCTAssertEqual(UserDefaults.standard.object(forKey: SettingsStore.petEnabledKey) as? Bool, true)
        XCTAssertEqual(UserDefaults.standard.object(forKey: SettingsStore.earsEnabledKey) as? Bool, false)
    }

    func testAnEmptyStoredAnimalIsStillTheStandardPetOnceResolved() {
        let stored = SettingsStore.storedPetChoice(animal: "", palette: "")
        XCTAssertEqual(PetChoiceRules.resolved(stored, in: Self.shipped), PetChoice.standard)
        XCTAssertEqual(
            PetChoiceRules.resolved(SettingsStore.storedPetChoice(animal: "raccoon", palette: nil), in: Self.shipped),
            PetChoice(animal: "raccoon", palette: "grey")
        )
    }
}

/// § 3.4, § 3.6, plan R17, R21: what an ear's open tells the navigation, and the card of each provider set.
final class P6VerificationNavigationTests: XCTestCase {
    private let routes: [IslandTransition.OpenRoute] = [.fresh, .reverse, .moveAndOpen]
    private let subjects: [String?] = [nil, "codex", "grok", "gone"]
    private let reveals: [PetCard?] = [nil, .agents, .keepAwake]
    private let four = ["claude", "codex", "antigravity", "grok"]

    func testEveryRouteSubjectAndCardAsksForWhatSectionThirtyFourSays() {
        for route in routes {
            for subject in subjects {
                for reveal in reveals {
                    let input = IslandNavigation.openInput(route: route, subject: subject, reveal: reveal)
                    if route == .reverse, subject == nil, reveal == nil {
                        XCTAssertNil(input, "a plain interrupted close keeps its page")
                    } else {
                        XCTAssertEqual(input, .open(subject: subject), "\(route) \(String(describing: subject)) \(String(describing: reveal))")
                    }
                }
            }
        }
    }

    func testWhereEachInputLandsFromEveryPage() {
        let pages: [IslandNavigation.Page] = [.all, .provider("claude"), .provider("grok")]
        for page in pages {
            for subject in subjects {
                let input = IslandNavigation.openInput(route: .fresh, subject: subject, reveal: nil)!
                let landed = IslandNavigation.reduce(page, input, providers: four).page
                switch subject {
                case "codex", "grok": XCTAssertEqual(landed, .provider(subject!), "from \(page)")
                default: XCTAssertEqual(landed, .all, "no subject, or one that is gone, lands at home: from \(page)")
                }
            }
        }
    }

    func testWithOneProviderEveryOpenLandsOnItsPageWhateverThePageWas() {
        for page in [IslandNavigation.Page.all, .provider("grok"), .provider("gone")] {
            for subject in subjects {
                let input = IslandNavigation.openInput(route: .moveAndOpen, subject: subject, reveal: .agents)!
                XCTAssertEqual(IslandNavigation.reduce(page, input, providers: ["grok"]).page, .provider("grok"), "\(page) \(String(describing: subject))")
            }
        }
        XCTAssertEqual(IslandNavigation.home(providers: ["grok"]), .provider("grok"))
    }

    func testTheAgentsCardOfEveryProviderSet() {
        let ids: [String?] = [nil, "claude", "codex", "grok", "antigravity", "", "Claude", "gemini"]
        for id in ids {
            for count in 0...5 {
                for sessions in [false, true] {
                    // Sessions of the page's own source only; `ProviderGridRulesAgentsCardTests` has the others.
                    let own = id.flatMap(AgentSource.init(rawValue:)) ?? .claude
                    let card = ProviderGridRules.agentsCard(
                        serviceID: id, providerCount: count, sessionSources: sessions ? [own] : []
                    )
                    let context = "\(String(describing: id)) of \(count), sessions \(sessions)"
                    switch id {
                    case nil: XCTAssertEqual(card, .allSessions, context)
                    case "claude": XCTAssertEqual(card, .provider(.claude), context)
                    case "codex": XCTAssertEqual(card, .provider(.codex), context)
                    default: XCTAssertEqual(card, count == 1 && sessions ? .allSessions : nil, context)
                    }
                }
            }
        }
    }

    func testTheEntryVerdictOfEveryEntryOnEveryIsland() {
        let entries: [IslandEntry] = [.statusItem(buttonFrame: .zero), .notch, .ear, .notification(pointer: .zero)]
        for entry in entries {
            XCTAssertEqual(IslandEventRules.entry(entry, isOpen: false, openScreenID: nil, entryScreenID: 1), .open, "\(entry) from closed")
            XCTAssertEqual(IslandEventRules.entry(entry, isOpen: false, openScreenID: 1, entryScreenID: 2), .open, "\(entry) from closed, stale ids")
        }
        XCTAssertEqual(IslandEventRules.entry(.ear, isOpen: true, openScreenID: 1, entryScreenID: 1), .stay)
        XCTAssertEqual(IslandEventRules.entry(.ear, isOpen: true, openScreenID: 1, entryScreenID: 2), .open, "R5: the island moves to the ear")
        XCTAssertEqual(IslandEventRules.entry(.statusItem(buttonFrame: .zero), isOpen: true, openScreenID: 1, entryScreenID: 2), .close)
        XCTAssertEqual(IslandEventRules.entry(.notch, isOpen: true, openScreenID: 1, entryScreenID: 1), .close)
        XCTAssertEqual(IslandEventRules.entry(.notch, isOpen: true, openScreenID: 1, entryScreenID: 2), .open)
    }
}
