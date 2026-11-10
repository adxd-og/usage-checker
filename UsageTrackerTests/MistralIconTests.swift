import AppKit
import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider, Decisions 3: Mistral's mark is bundled as the other
/// providers' are, a template image `ProviderIconView` finds by the service id `mistral`.
final class MistralIconTests: XCTestCase {
    func testMistralsMarkIsBundledUnderItsServiceIDAsATemplate() throws {
        let image = try XCTUnwrap(NSImage(named: "ProviderIcon-mistral"))
        XCTAssertTrue(image.isTemplate, "tinted like the other logos")
    }
}
