import Combine
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Roster, § 3.7: the pet and the ears are on and the cat in
/// ginger is chosen until the user says otherwise; each is published at once, so the island and the
/// ears follow, and a reset forgets them. Writes the app's real defaults domain, so the domain is
/// snapshotted and handed back through `AppDomainRestore`.
final class SettingsStorePetTests: XCTestCase {
    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    @MainActor
    func testThePetAndTheEarsAreOnWithTheCatInGingerByDefault() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        XCTAssertTrue(settings.petEnabled)
        XCTAssertTrue(settings.earsEnabled)
        XCTAssertEqual(settings.petChoice, PetChoice(animal: "cat", palette: "ginger"))
    }

    @MainActor
    func testEachSwitchIsStoredUnderItsOwnKey() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        settings.petEnabled = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: SettingsStore.petEnabledKey) as? Bool, false)
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.earsEnabledKey))
        settings.earsEnabled = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: SettingsStore.earsEnabledKey) as? Bool, false)
    }

    @MainActor
    func testAChosenPetIsOneChangeAndBothKeysAreWritten() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        var sent: [PetChoice] = []
        let watch = settings.$petChoice.dropFirst().sink { sent.append($0) }
        let duck = PetChoice(animal: "duck", palette: "mallard")
        settings.petChoice = duck
        watch.cancel()
        XCTAssertEqual(sent, [duck], "no half-changed pair goes out")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsStore.petAnimalKey), "duck")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsStore.petPaletteKey), "mallard")
    }

    /// Plan ruling R2 rests on this: a click on the stored pair is still a word from Settings.
    @MainActor
    func testReChoosingTheSamePairIsStillHeard() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        var sent: [PetChoice] = []
        let watch = settings.$petChoice.dropFirst().sink { sent.append($0) }
        settings.petChoice = PetChoice.standard
        watch.cancel()
        XCTAssertEqual(sent, [PetChoice.standard])
    }

    /// The keys can hold what the store never saw: a domain put back by `AppDomainRestore`, or another
    /// copy of the app sharing it.
    @MainActor
    func testResetForgetsThemEvenIfTheStoreNeverSawTheValue() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        for key in [SettingsStore.petEnabledKey, SettingsStore.earsEnabledKey] {
            UserDefaults.standard.set(false, forKey: key)
        }
        UserDefaults.standard.set("duck", forKey: SettingsStore.petAnimalKey)
        UserDefaults.standard.set("mallard", forKey: SettingsStore.petPaletteKey)
        settings.resetToDefaults()
        for key in [
            SettingsStore.petEnabledKey, SettingsStore.earsEnabledKey,
            SettingsStore.petAnimalKey, SettingsStore.petPaletteKey,
        ] {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), key)
        }
    }

    func testNothingStoredIsTheStandardPet() {
        XCTAssertEqual(SettingsStore.storedPetChoice(animal: nil, palette: nil), PetChoice.standard)
        XCTAssertEqual(SettingsStore.storedPetChoice(animal: nil, palette: "cream"), PetChoice.standard)
    }

    /// An empty palette resolves to the animal's first (`PetChoiceRules.resolved`).
    func testAStoredAnimalWithoutAPaletteKeepsTheAnimal() {
        XCTAssertEqual(
            SettingsStore.storedPetChoice(animal: "dog", palette: nil), PetChoice(animal: "dog", palette: "")
        )
        XCTAssertEqual(
            SettingsStore.storedPetChoice(animal: "dog", palette: "tan"), PetChoice(animal: "dog", palette: "tan")
        )
    }
}
