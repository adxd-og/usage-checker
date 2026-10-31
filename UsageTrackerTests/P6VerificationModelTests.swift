import Combine
import XCTest
@testable import Omelette

/// Tester's verification of P6, the models (notch-island spec 2026-10-29 § 3.5 Jump from the island, § 3.6,
/// § 3.7, plan rulings R2, R6, R13, R19, R20): the ear's jump ticket across every interleaving, the
/// stored choice against Debug's override, the picker's rules and the preview gate.
@MainActor
final class P6VerificationJumpTicketTests: XCTestCase {
    private final class Log {
        var closes = 0
        var fallbacks = 0
    }

    private func make() -> (model: IslandPetModel, log: Log) {
        let log = Log()
        let model = IslandPetModel(keeper: PetKeeper(random: PetRandom { 0 }), clock: { PetRuntimeFixture.t0 })
        model.closeIsland = { log.closes += 1 }
        return (model, log)
    }

    private func start(_ model: IslandPetModel, _ log: Log) -> @MainActor @Sendable (Bool) -> Void {
        model.earJumpStarted(orElse: { log.fallbacks += 1 })
    }

    /// Every event that happens between the jump and its answer, and what the answer may then do.
    func testTheAnswerOfAnEarJumpAfterEachInterveningEvent() {
        enum Between: CaseIterable { case nothing, opened, closed, newerEarJump, rowJump, earStays, openedThenClosed }
        for between in Between.allCases {
            for landed in [true, false] {
                let (model, log) = make()
                let answer = start(model, log)
                switch between {
                case .nothing: break
                case .opened: model.islandOpened()
                case .closed: model.islandClosed()
                case .newerEarJump: _ = start(model, log)
                case .rowJump: _ = model.jumpStarted()
                case .earStays: _ = model.entryVerdict(.ear, isOpen: true, openScreenID: 1, entryScreenID: 1)
                case .openedThenClosed:
                    model.islandOpened()
                    model.islandClosed()
                }
                answer(landed)
                let context = "\(between), landed: \(landed)"
                if between == .nothing {
                    XCTAssertEqual(log.closes, landed ? 1 : 0, context)
                    XCTAssertEqual(log.fallbacks, landed ? 0 : 1, context)
                } else {
                    XCTAssertEqual(log.closes, 0, "a stale answer closes nothing: \(context)")
                    XCTAssertEqual(log.fallbacks, 0, "a stale answer opens nothing: \(context)")
                }
            }
        }
    }

    func testTheNewerJumpAnswersAndTheOlderOneStaysSilentWhicheverComesFirst() {
        for olderFirst in [true, false] {
            let (model, log) = make()
            let older = start(model, log)
            let newer = start(model, log)
            if olderFirst { older(true); newer(true) } else { newer(true); older(true) }
            XCTAssertEqual(log.closes, 1, "olderFirst: \(olderFirst)")
        }
    }

    func testAnAnswerGivenTwiceActsOnce() {
        for first in [true, false] {
            for second in [true, false] {
                let (model, log) = make()
                let answer = start(model, log)
                answer(first)
                answer(second)
                if first {
                    XCTAssertEqual(log.closes, 1, "\(first) then \(second)")
                    XCTAssertEqual(log.fallbacks, 0, "a landed jump is not a failure after all: \(first) then \(second)")
                } else {
                    XCTAssertEqual(log.fallbacks, 1, "\(first) then \(second)")
                    XCTAssertEqual(log.closes, 0, "a failed jump is spent: \(first) then \(second)")
                }
            }
        }
    }

    func testAnAnswerThatOutlivesItsModelDoesNothing() {
        let log = Log()
        var answer: (@MainActor @Sendable (Bool) -> Void)?
        do {
            let model = IslandPetModel(keeper: PetKeeper(random: PetRandom { 0 }), clock: { PetRuntimeFixture.t0 })
            model.closeIsland = { log.closes += 1 }
            answer = model.earJumpStarted(orElse: { log.fallbacks += 1 })
        }
        answer?(false)
        answer?(true)
        XCTAssertEqual(log.closes + log.fallbacks, 0)
    }

    func testTheVerdictsAnEarGetsAndWhichOfThemTakeTheTicket() {
        let cases: [(isOpen: Bool, open: UInt32?, entry: UInt32?, verdict: IslandEventRules.EntryVerdict, voids: Bool)] = [
            (false, nil, 1, .open, false),
            (true, 1, 1, .stay, true),
            (true, 1, 2, .open, false),
        ]
        for item in cases {
            let (model, log) = make()
            let answer = start(model, log)
            XCTAssertEqual(model.entryVerdict(.ear, isOpen: item.isOpen, openScreenID: item.open, entryScreenID: item.entry), item.verdict)
            answer(false)
            XCTAssertEqual(log.fallbacks, item.voids ? 0 : 1, "\(item)")
        }
    }
}

/// § 3.7, plan R2, R19: Settings speaks to the model as it is chosen; Debug's animal gives way.
@MainActor
final class P6VerificationChoiceFollowTests: XCTestCase {
    private static let shipped = PetLibrary.bundled()
    private final class Source { @Published var choice = PetChoice.standard }
    private final class Count { var heard = 0 }

    private func make(_ source: Source, _ count: Count) -> IslandPetModel {
        let model = IslandPetModel(keeper: PetKeeper(random: PetRandom { 0 }), clock: { PetRuntimeFixture.t0 })
        model.onPetChange = { count.heard += 1 }
        model.follow(source.$choice)
        return model
    }

    func testFollowingStartsWithTheCurrentPairAndHearsNothingNew() {
        let count = Count()
        let source = Source()
        let model = make(source, count)
        XCTAssertEqual(count.heard, 0)
        XCTAssertEqual(model.choice, PetChoice.standard)
        let duck = PetChoice(animal: "duck", palette: "mallard")
        source.choice = duck
        source.choice = PetChoice(animal: "duck", palette: "white")
        source.choice = PetChoice(animal: "duck", palette: "white")
        XCTAssertEqual(count.heard, 2, "each different pair is one change, a repeat is none")
        XCTAssertEqual(model.shown(in: Self.shipped), PetChoice(animal: "duck", palette: "white"))
    }

    func testFollowingAgainDropsTheOldSource() {
        let count = Count()
        let first = Source()
        let model = make(first, count)
        let second = Source()
        model.follow(second.$choice)
        first.choice = PetChoice(animal: "dog", palette: "tan")
        XCTAssertEqual(count.heard, 0, "the first source is no longer followed")
        second.choice = PetChoice(animal: "raccoon", palette: "grey")
        XCTAssertEqual(count.heard, 1)
    }

    #if DEBUG
    /// The head and the tips follow the pet shown, so the end of Debug's animal is a change of pet even
    /// when the stored pair is the one chosen again.
    func testReChoosingTheStoredPairUnderADebugAnimalIsHeardOnceAndShowsTheStoredPet() {
        let count = Count()
        let source = Source()
        let model = make(source, count)
        model.showDebugAnimal("duck")
        XCTAssertEqual(count.heard, 1, "Debug's own change")
        XCTAssertEqual(model.shown(in: Self.shipped)?.animal, "duck")
        source.choice = PetChoice.standard
        XCTAssertEqual(count.heard, 2, "the head is rebuilt for the pet that comes back")
        XCTAssertEqual(model.shown(in: Self.shipped), PetChoice.standard)
        source.choice = PetChoice.standard
        XCTAssertEqual(count.heard, 2, "with no override a repeat is nothing")
    }

    func testANewPairUnderADebugAnimalWins() {
        let count = Count()
        let source = Source()
        let model = make(source, count)
        model.showDebugAnimal("raccoon")
        source.choice = PetChoice(animal: "dog", palette: "cream")
        XCTAssertEqual(model.shown(in: Self.shipped), PetChoice(animal: "dog", palette: "cream"))
        XCTAssertEqual(model.animal, "dog")
        XCTAssertEqual(count.heard, 2)
    }

    func testDebugsAnimalIsNotWrittenToTheChoiceAndASecondDebugPickReplacesTheFirst() {
        let count = Count()
        let source = Source()
        let model = make(source, count)
        model.showDebugAnimal("duck")
        model.showDebugAnimal("raccoon")
        XCTAssertEqual(model.choice, PetChoice.standard, "in memory only")
        XCTAssertEqual(source.choice, PetChoice.standard)
        XCTAssertEqual(model.shown(in: Self.shipped)?.animal, "raccoon")
    }

    func testAnOverrideAndAChoiceTheLibraryLacksAreBothAnsweredWithAPetThatExists() {
        let model = IslandPetModel(keeper: PetKeeper(random: PetRandom { 0 }), clock: { PetRuntimeFixture.t0 })
        model.showDebugAnimal("otter")
        model.setChoice(PetChoice(animal: "walrus", palette: "x"))
        XCTAssertEqual(model.shown(in: Self.shipped), PetChoice.standard)
        XCTAssertNil(model.shown(in: .empty))
    }
    #endif
}

/// § 3.7, plan R13: the picker's rules, in the cases the page tests leave.
final class P6VerificationPickerTests: XCTestCase {
    private static let shipped = PetLibrary.bundled()

    func testTheLoopTruthTableIsAllThreeAtOnce() {
        let columns = PetPickerRules.columns(library: Self.shipped, selected: .standard)
        let selected = columns.flatMap(\.cells).first(where: \.isSelected)!
        let other = columns.flatMap(\.cells).first(where: { !$0.isSelected })!
        for cell in [selected, other] {
            for gate in [true, false] {
                for pet in [true, false] {
                    XCTAssertEqual(
                        PetPickerRules.loops(cell, gateOn: gate, petOn: pet),
                        cell.isSelected && gate && pet, "selected:\(cell.isSelected) gate:\(gate) pet:\(pet)"
                    )
                }
            }
        }
    }

    func testEveryShippedPairSelectsExactlyItsOwnCellAndAnAbsentPairSelectsNone() {
        let all = PetPickerRules.columns(library: Self.shipped, selected: .standard).flatMap(\.cells).map(\.choice)
        XCTAssertEqual(all.count, 12)
        XCTAssertEqual(Set(all).count, 12, "twelve distinct cells")
        for choice in all {
            let cells = PetPickerRules.columns(library: Self.shipped, selected: choice).flatMap(\.cells)
            XCTAssertEqual(cells.filter(\.isSelected).map(\.choice), [choice])
        }
        for stale in [PetChoice(animal: "otter", palette: "x"), PetChoice(animal: "cat", palette: "pink"), PetChoice(animal: "", palette: "")] {
            XCTAssertTrue(PetPickerRules.columns(library: Self.shipped, selected: stale).flatMap(\.cells).allSatisfy { !$0.isSelected }, "\(stale)")
        }
    }

    func testThePreviewNeverIndexesOutsideItsFramesWhateverTheDateOrRate() {
        for fps in [0.5, 1.0, 3.0, 4.0, 7.5, 12.0] {
            for count in 1...4 {
                let frames = (0..<count).map { "f\($0)" }
                let animation = PetAnimation(frames: frames, fps: fps)
                for seconds in stride(from: -1_000_000.0, through: 1_000_000.0, by: 99_991.7) {
                    XCTAssertTrue(frames.contains(PetPickerRules.frameName(of: animation, at: Date(timeIntervalSinceReferenceDate: seconds))), "\(fps) \(count) \(seconds)")
                }
            }
        }
    }

    func testTheSelectedPreviewAdvancesOneFrameEveryFrameDuration() {
        let animation = PetAnimation(frames: ["a", "b", "c"], fps: 4)
        let names = (0..<12).map { PetPickerRules.frameName(of: animation, at: Date(timeIntervalSinceReferenceDate: 100 + Double($0) * 0.25 + 0.01)) }
        XCTAssertEqual(names, (0..<12).map { ["a", "b", "c"][(400 + $0) % 3] })
    }
}

/// § 3.7: the preview gate is the pet's own, with the picker's window as the surface.
@MainActor
final class P6VerificationPreviewGateTests: XCTestCase {
    func testItAnimatesInExactlyTheOneCombinationOfFiveConditions() {
        for bits in 0..<32 {
            let shown = bits & 1 != 0, visible = bits & 2 != 0, awake = bits & 4 != 0, locked = bits & 8 != 0, reduce = bits & 16 != 0
            let model = PetPreviewGateModel()
            model.setShown(shown)
            model.setWindowVisible(visible)
            model.setDisplayAwake(awake)
            model.setScreenLocked(locked)
            model.setReduceMotion(reduce)
            XCTAssertEqual(model.animates, shown && visible && awake && !locked && !reduce, "bits \(bits)")
        }
    }
}

/// § 3.5 Rendering, § 3.7, P5d Review Focus 5: what the picker and the ears build never lets events start.
final class P6VerificationWarmthTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P6VerificationWarmthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object = PetFixture.setting(["events"], to: [PetFixture.event()], in: PetFixture.manifest())
        try PetFixture.write(object, folder: PetFixture.id, in: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testNeitherTheEarNorThePickerMakesEventsPlayableInAnyOrderAndThePetsOwnWarmUpStaysWarm() throws {
        let library = PetLibrary.load(from: directory)
        let manifest = try XCTUnwrap(library.manifests[PetFixture.id])
        func playable(_ cache: PetSpriteCache, _ palette: String = "grey") -> [String] {
            PetHabitatRules.playableEvents(of: manifest, palette: palette, pixelsPerBead: 3, sprites: cache).map(\.id)
        }
        let choice = PetChoice(animal: PetFixture.id, palette: "grey")

        let cold = PetSpriteCache(library: library)
        cold.prewarmEar(animal: PetFixture.id, palette: "grey", pixelsPerBead: 3)
        cold.prewarmPicker(cells: [choice], selected: choice, pixelsPerBead: 3)
        XCTAssertEqual(playable(cold), [], "a visit to Settings and a hover never start events")

        cold.prewarm(animal: PetFixture.id, palette: "grey", pixelsPerBead: 3)
        XCTAssertEqual(playable(cold), ["hop"])
        let built = cold.count
        cold.prewarmPicker(cells: [choice], selected: choice, pixelsPerBead: 3)
        cold.prewarmEar(animal: PetFixture.id, palette: "grey", pixelsPerBead: 3)
        XCTAssertEqual(cold.count, built, "nothing is built twice")
        XCTAssertEqual(playable(cold), ["hop"], "warm stays warm")
        XCTAssertEqual(playable(cold, "pink"), [], "a palette the pet lacks never plays, whoever else is warm")
        XCTAssertEqual(playable(cold, "white"), [], "a palette not warmed is not playable")
    }

    func testThePickerIsDrawnFromTheCacheAfterTheOffMainWarmUpAndNotBeforeItBuilds() throws {
        let library = PetLibrary.load(from: directory)
        let cache = PetSpriteCache(library: library)
        let key = PetSpriteCache.Key(animal: PetFixture.id, palette: "grey", sprite: .frame(try XCTUnwrap(library.manifests[PetFixture.id]).still.idle), pixelsPerBead: 3)
        XCTAssertNil(cache.cachedImage(key), "nothing before the warm-up")
        let choice = PetChoice(animal: PetFixture.id, palette: "grey")
        cache.prewarmPicker(cells: [choice, PetChoice(animal: PetFixture.id, palette: "pink")], selected: choice, pixelsPerBead: 3)
        XCTAssertNotNil(cache.cachedImage(key))
        XCTAssertNil(cache.cachedImage(PetSpriteCache.Key(animal: PetFixture.id, palette: "pink", sprite: key.sprite, pixelsPerBead: 3)), "a palette the pet lacks builds nothing")
    }
}
