import AppKit
import SwiftUI

/// The picker Settings › Pet and onboarding share (notch-island spec 2026-10-29 § 3.7): the animals in
/// their palettes, one click choosing both. Stills, the chosen one looping under `PetAnimationGate`
/// with this window as the surface. What it draws is built off the main thread and read without
/// building (`prewarmPicker`, `drawableImage`). `PetPickerRules` decides; this view draws.
struct PetPickerView: View {
    /// The pet is off: dimmed, still clickable, nothing loops (plan OWNER 8).
    var dimmed = false

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var store = PetAssetStore.shared
    @StateObject private var gate = PetPreviewGateModel()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts the warm-ups that finished: its landing redraws the cells.
    @State private var warmups = 0

    private static let cellPadding: CGFloat = 5
    private static let labelSize: CGFloat = 11
    private static let cornerRadius: CGFloat = 10
    private static let dimmedOpacity = 0.5

    var body: some View {
        let _ = warmups
        Group {
            if let assets = store.assets, let selected = PetChoiceRules.resolved(settings.petChoice, in: assets.library) {
                grid(assets, selected: selected)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .opacity(dimmed ? Self.dimmedOpacity : 1)
        .background(WindowVisibilityReader { visible in
            gate.setWindowVisible(visible)
        })
        .onAppear { gate.setShown(true) }
        .onDisappear { gate.setShown(false) }
        .onChange(of: reduceMotion, initial: true) { _, reduced in
            gate.setReduceMotion(reduced)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
            gate.setDisplayAwake(false)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in
            gate.setDisplayAwake(true)
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))) { _ in
            gate.setScreenLocked(true)
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsUnlocked"))) { _ in
            gate.setScreenLocked(false)
        }
        .task(id: warmKey) {
            guard let warmKey, let sprites = store.assets?.sprites else { return }
            await Task.detached(priority: .utility) {
                sprites.prewarmPicker(cells: warmKey.cells, selected: warmKey.selected, pixelsPerBead: warmKey.pixels)
            }.value
            warmups += 1
        }
    }

    private var scale: PetScaleRules.Scale {
        PetHabitatRules.scale(petBeads: PetContract.size, backingScale: displayScale)
    }

    /// What is warmed: every cell, and the chosen pet, at this display's scale.
    private struct WarmKey: Hashable {
        let cells: [PetChoice]
        let selected: PetChoice
        let pixels: Int
    }

    private var warmKey: WarmKey? {
        guard let library = store.assets?.library,
              let selected = PetChoiceRules.resolved(settings.petChoice, in: library)
        else { return nil }
        return WarmKey(
            cells: PetPickerRules.columns(library: library, selected: selected).flatMap(\.cells).map(\.choice),
            selected: selected,
            pixels: scale.pixelsPerBead
        )
    }

    private func grid(_ assets: PetAssets, selected: PetChoice) -> some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(PetPickerRules.columns(library: assets.library, selected: selected)) { column in
                VStack(spacing: 2) {
                    Text(column.name)
                        .font(.system(size: Self.labelSize, weight: .semibold))
                        .foregroundStyle(.om(.text))
                        .accessibilityAddTraits(.isHeader)
                    if let manifest = assets.library.manifests[column.animal] {
                        ForEach(column.cells) { cell in
                            cellView(cell, manifest: manifest, sprites: assets.sprites)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func cellView(_ cell: PetPickerCell, manifest: PetManifest, sprites: PetSpriteCache) -> some View {
        let side = scale.points(beads: manifest.size)
        let idle = manifest.animations.idle
        return Button {
            settings.petChoice = cell.choice
        } label: {
            VStack(spacing: 2) {
                Group {
                    if PetPickerRules.loops(cell, gateOn: gate.animates, petOn: !dimmed) {
                        TimelineView(.periodic(from: PetHabitatRules.timelineAnchor, by: 1 / idle.fps)) { context in
                            sprite(.frame(PetPickerRules.frameName(of: idle, at: context.date)), cell, manifest, sprites)
                        }
                    } else {
                        sprite(.frame(manifest.still.idle), cell, manifest, sprites)
                    }
                }
                .frame(width: side, height: side)
                Text(cell.paletteName)
                    .font(.system(size: Self.labelSize))
                    .foregroundStyle(.om(cell.isSelected ? .text : .secondary))
                    .lineLimit(1)
            }
            .padding(Self.cellPadding)
            .frame(maxWidth: .infinity)
            .background {
                if cell.isSelected {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(.om(.track))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cell.accessibilityLabel)
        .accessibilityAddTraits(cell.isSelected ? .isSelected : [])
    }

    /// The frame if it is built, the still if not, nothing until the warm-up lands.
    @ViewBuilder
    private func sprite(_ sprite: PetSprite, _ cell: PetPickerCell, _ manifest: PetManifest, _ sprites: PetSpriteCache) -> some View {
        if let image = sprites.drawableImage(
            PetSpriteCache.Key(
                animal: cell.choice.animal, palette: cell.choice.palette,
                sprite: sprite, pixelsPerBead: scale.pixelsPerBead
            ),
            orStill: .frame(manifest.still.idle)
        ) {
            Image(decorative: image, scale: scale.backingScale)
                .interpolation(.none)
        }
    }
}
