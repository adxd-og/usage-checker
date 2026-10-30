#if DEBUG
import SwiftUI

/// The pet's right-click menu in a Debug build (notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30
/// (events)"): the shown animal's events, "Play all in order", the four animals. `PetDebugMenuRules`
/// decides what it lists; this view lists it.
struct PetDebugMenuContent: View {
    let menu: PetDebugMenu
    let play: @MainActor (String) -> Void
    let playAll: @MainActor () -> Void
    let show: @MainActor (String) -> Void

    var body: some View {
        if let note = menu.note {
            Text(note)
        }
        ForEach(menu.eventIDs, id: \.self) { id in
            Button(id) {
                play(id)
            }
            .disabled(!menu.canPlay)
        }
        Button(PetDebugMenuRules.playAllTitle) {
            playAll()
        }
        .disabled(!menu.canPlay)
        Divider()
        ForEach(menu.animals, id: \.id) { animal in
            Button {
                show(animal.id)
            } label: {
                if animal.isShown {
                    Label(animal.id, systemImage: "checkmark")
                } else {
                    Text(animal.id)
                }
            }
        }
    }
}
#endif
