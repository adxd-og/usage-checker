import SwiftUI

/// The pet's column on the island (notch-island spec 2026-10-29 § 3.3 "Left, 150 pt: the
/// habitat", § 3.5, § 3.8): the pet on the floor at the column's bottom in its mood's pose,
/// whatever the mood (owner 2026-10-30), the mood line under it, the sky's mark at the top, the
/// column one accessibility element whose label is the mood's and whose action is the click. No
/// fill and no edge. While `PetAnimationGate` is on, one `TimelineView` at the playing animation's
/// rate draws the keeper's frames; while it is off, the mood's still and no animation timeline.
/// While the island is open the mood and the sky are read again at every minute (Codex review 5);
/// closed, nothing ticks. The keeper is paused and resumed by `IslandPetModel` the moment a
/// condition changes, never by this view (Codex review 4). The rules decide (`PetHabitatRules`,
/// `PetActionRules`, `PetAnimationGate`); this view reads the app's state and draws.
struct PetHabitatView: View {
    /// The gate's conditions, the app's pet runtime, the jumps and the close.
    @ObservedObject var pet: IslandPetModel
    /// The column's height: the right column's on screen.
    let height: CGFloat
    /// The page shown and the providers on screen, for where a click goes (`PetActionRules`).
    let page: IslandNavigation.Page
    let providers: [String]
    /// What the island does for a click, a pat aside (the habitat's own); nil drops it.
    var onEffect: ((PetEffect) -> Void)? = nil

    @ObservedObject private var state = AppState.shared
    @ObservedObject private var agents = AgentSessionStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var keepAwake = KeepAwakeModel.shared
    @ObservedObject private var claudeSignIn = ClaudeSignInModel.shared
    @ObservedObject private var store = PetAssetStore.shared
    @Environment(\.displayScale) private var displayScale

    /// The playing animation's rate as the last frame gave it, for the timeline's period; nil
    /// before the first frame.
    @State private var playingFPS: Double?
    /// The last pat: a still pet redraws once its heart is due to go.
    @State private var lastPat: Date?

    /// A pat's heart over the pet's head (§ 3.5 rows 5 and 7, "♥ 1.2 s").
    nonisolated static let heartSize: CGFloat = 11
    nonisolated static let heartColor = Color.pink

    /// The app's pet runtime, through the model; never observed.
    private var keeper: PetKeeper { pet.keeper }

    var body: some View {
        Group {
            if let assets = store.assets, let manifest = assets.library.manifests[PetHabitatRules.animal] {
                if pet.islandOpen {
                    // Night, the sky and keep awake's clock turn on the minute while the island
                    // is open, Reduce Motion or not.
                    TimelineView(.everyMinute) { context in
                        habitat(manifest, assets, now: context.date)
                    }
                } else {
                    habitat(manifest, assets, now: Date())
                }
            } else {
                // The manifests are not read yet, or the pet failed its contract check (P5a): the
                // column stays bare.
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(width: ProviderGridRules.habitatWidth, height: height, alignment: .topLeading)
        // The habitat in the island's content is one of the gate's conditions.
        .onAppear {
            pet.setHabitatShown(true)
        }
        .onDisappear {
            pet.setHabitatShown(false)
        }
        // Every frame of the pet shown, its events' too, at this display's scale, built off the main
        // thread once the assets are there and when one of these changes, so no frame is built while
        // drawing (`PetSpriteCache.prewarm`): one animal, one palette, one scale.
        .task(id: warmth) {
            guard let warmth, let sprites = store.assets?.sprites else { return }
            await Task.detached(priority: .utility) {
                sprites.prewarm(animal: warmth.animal, palette: warmth.palette, pixelsPerBead: warmth.pixels)
            }.value
        }
        // A still pet's heart goes when the pat's 1.2 s are up: one redraw then. A newer pat
        // cancels the wait and starts its own; a running timeline redraws on its own.
        .task(id: lastPat) {
            guard lastPat != nil else { return }
            guard (try? await Task.sleep(for: .seconds(PetRuntime.patDuration))) != nil else { return }
            lastPat = nil
        }
    }

    private var pixelsPerBead: Int {
        PetHabitatRules.scale(petBeads: PetContract.size, backingScale: displayScale).pixelsPerBead
    }

    /// What the sprites are warmed for.
    private struct Warmth: Hashable {
        let animal: String
        let palette: String
        let pixels: Int
    }

    /// Nil until the assets are there.
    private var warmth: Warmth? {
        guard store.assets != nil else { return nil }
        return Warmth(animal: PetHabitatRules.animal, palette: PetHabitatRules.palette, pixels: pixelsPerBead)
    }

    /// What the mood is decided from: the app's state as it is published (`PetMoodInput`).
    private var moodInput: PetMoodInput {
        PetMoodInput(
            sessions: agents.sessions,
            services: state.snapshot.services,
            enabledIDs: state.polledIDs,
            claudeBinaryFound: claudeSignIn.binaryFound,
            keepAwake: keepAwake.state
        )
    }

    /// What every frame of one draw shares.
    private struct Placement {
        let manifest: PetManifest
        let sprites: PetSpriteCache
        let scale: PetScaleRules.Scale
        let roam: Int
        let footY: CGFloat
        let action: PetAction
    }

    /// The sky, the pet on the floor in its mood's pose, and the mood line under it, at `now`.
    private func habitat(_ manifest: PetManifest, _ assets: PetAssets, now: Date) -> some View {
        let scene = PetHabitatRules.scene(
            moodInput, petName: manifest.name, mode: settings.percentMode,
            now: now, calendar: .current, locale: .current
        )
        let presentation = scene.presentation
        let scale = PetHabitatRules.scale(petBeads: manifest.size, backingScale: displayScale)
        let place = Placement(
            manifest: manifest,
            sprites: assets.sprites,
            scale: scale,
            roam: PetHabitatRules.roamBeads(petBeads: manifest.size, scale: scale),
            footY: PetHabitatRules.floorY(height: height, petSide: scale.points(beads: manifest.size)),
            action: presentation.action
        )
        let still = PetRuntime.still(pose: presentation.pose, stills: manifest.still)
        let poseFPS = manifest.animations[presentation.pose.animation].fps
        let period = PetAnimationGate.framePeriod(pet.conditions, fps: playingFPS ?? poseFPS)
        return ZStack(alignment: .topLeading) {
            sky(scene.sky)
            if let period {
                TimelineView(.periodic(from: PetHabitatRules.timelineAnchor, by: period)) { context in
                    let frame = keeper.frame(
                        at: context.date, presentation: presentation,
                        animations: manifest.animations, roamBeads: place.roam
                    )
                    sprite(
                        frame?.frame ?? still,
                        xBeads: frame?.xBeads ?? keeper.runtime.xBeads,
                        facesLeft: frame?.facesLeft ?? keeper.runtime.facesLeft,
                        heart: frame?.showsHeart ?? keeper.showsHeart(at: Date()),
                        place: place
                    )
                    // The playing rate sets the next period: a walk ticks at 8 fps, idle at 2.
                    .onChange(of: frame?.fps, initial: true) { _, rate in
                        if let rate { playingFPS = rate }
                    }
                }
            } else {
                sprite(
                    still,
                    xBeads: keeper.runtime.xBeads,
                    facesLeft: keeper.runtime.facesLeft,
                    heart: keeper.showsHeart(at: Date()),
                    place: place
                )
            }
            moodLine(presentation.line)
        }
        // One element for VoiceOver (§ 3.8): the mood's label, the click as its action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityAddTraits(PetActionRules.isActionable(presentation.action) ? .isButton : [])
        .accessibilityAction {
            click(presentation.action)
        }
    }

    /// The sky: one small mark at the column's top right following the local clock, behind the
    /// pet (§ 3.3; owner 2026-10-30: no fill, no edge; the sky stays).
    private func sky(_ sky: PetSky) -> some View {
        Image(systemName: PetSkyRules.symbol(sky))
            .font(.system(size: PetSkyRules.symbolSize))
            .foregroundStyle(.om(.muted))
            .frame(width: ProviderGridRules.habitatWidth, alignment: .topTrailing)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    /// One frame of the pet: the button a click goes through, on whole beads on the floor and on
    /// the device-pixel grid, mirrored when it last walked left, the heart over its head.
    private func sprite(
        _ frame: String, xBeads: Int, facesLeft: Bool, heart: Bool, place: Placement
    ) -> some View {
        let side = place.scale.points(beads: place.manifest.size)
        let origin = PetHabitatRules.origin(
            xBeads: xBeads, footY: place.footY, petBeads: place.manifest.size,
            roamBeads: place.roam, scale: place.scale
        )
        let image = place.sprites.image(PetSpriteCache.Key(
            animal: PetHabitatRules.animal, palette: PetHabitatRules.palette,
            sprite: .frame(frame), pixelsPerBead: place.scale.pixelsPerBead
        ))
        return Button {
            click(place.action)
        } label: {
            ZStack {
                if let image {
                    Image(decorative: image, scale: place.scale.backingScale)
                        .interpolation(.none)
                        .scaleEffect(x: facesLeft ? -1 : 1, y: 1)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if heart {
                Image(systemName: "heart.fill")
                    .font(.system(size: Self.heartSize))
                    .foregroundStyle(Self.heartColor)
                    .offset(y: -Self.heartSize - 2)
            }
        }
        .offset(x: origin.x, y: origin.y)
    }

    /// The mood's words at the column's bottom, under the floor (§ 3.3); none while idle.
    private func moodLine(_ line: String?) -> some View {
        Text(line ?? "")
            .font(.system(size: PetHabitatRules.moodLineSize))
            .foregroundStyle(.om(.secondary))
            .multilineTextAlignment(.center)
            .lineLimit(PetHabitatRules.moodLineLimit)
            .truncationMode(.tail)
            .textSelection(.disabled)
            .frame(width: ProviderGridRules.habitatWidth, height: PetHabitatRules.moodBand, alignment: .bottom)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
    }

    /// A click on the pet, or VoiceOver's action on the habitat: a pat is the habitat's own, the
    /// rest the island's (`PetActionRules`).
    private func click(_ action: PetAction) {
        for effect in PetActionRules.effects(of: action, page: page, providers: providers) {
            if effect == .pat {
                let now = Date()
                keeper.pat(at: now)
                lastPat = now
            } else {
                onEffect?(effect)
            }
        }
    }
}
