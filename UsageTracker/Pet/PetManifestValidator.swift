import Foundation

/// What breaks the pet manifest contract (notch-island spec 2026-10-29 § 3.5). Each case says
/// what P4's art validator said for the same fault.
enum PetManifestIssue: Equatable, Sendable, CustomStringConvertible {
    /// The folder has no pet.json.
    case noManifest
    /// The file is not JSON.
    case unreadable
    /// Contract keys the manifest lacks, in the contract's order; the check stops after them.
    case missingKeys([String])
    /// Keys the contract does not have, alphabetical.
    case extraKeys([String])
    case idMismatch(id: String, folder: String)
    case emptyName
    /// `size` is not the number 35.
    case badSize
    case noPalettes
    case paletteNotObject(String)
    case transparentRole(palette: String)
    /// A role that is not exactly one Unicode scalar ("ab", or "e" + U+0301).
    case roleNotOneCharacter(palette: String, role: String)
    case badColour(palette: String, role: String)
    case noFrames
    /// A map without `expected` rows, or not a list of rows.
    case rowCount(PetSprite, expected: Int)
    /// A row that is not `expected` beads (Unicode scalars) long, or not a string.
    case rowLength(PetSprite, row: Int, expected: Int)
    case undeclaredRole(PetSprite, x: Int, y: Int, role: Unicode.Scalar)
    /// Roles the maps use that this palette has no colour for, sorted.
    case paletteLacksRoles(palette: String, roles: String)
    case missingAnimation(PetAnimationName)
    case animationWithoutFrames(String)
    case animationUnknownFrame(animation: String, frame: String)
    /// fps is not a number from 0.5 to 12.
    case animationFps(String)
    case stillMissing(PetPose)
    case stillUnknownFrame(PetPose, frame: String)

    var description: String {
        switch self {
        case .noManifest: "no pet.json"
        case .unreadable: "pet.json is not JSON"
        case .missingKeys(let keys): "missing keys: \(keys.joined(separator: ", "))"
        case .extraKeys(let keys): "keys outside the contract: \(keys.joined(separator: ", "))"
        case .idMismatch(let id, let folder): "id \(id) != folder \(folder)"
        case .emptyName: "name empty"
        case .badSize: "size is not \(PetContract.size)"
        case .noPalettes: "palettes empty"
        case .paletteNotObject(let palette): "palette \(palette) is not an object"
        case .transparentRole(let palette): "palette \(palette): \".\" is transparent and may not be a role"
        case .roleNotOneCharacter(let palette, let role): "palette \(palette): role \(role) is not one character (Unicode scalar)"
        case .badColour(let palette, let role): "palette \(palette): role \(role) colour is not #rrggbb"
        case .noFrames: "frames empty"
        case .rowCount(let sprite, let expected): "\(sprite): expected \(expected) rows"
        case .rowLength(let sprite, let row, let expected): "\(sprite) row \(row): expected \(expected) beads"
        case .undeclaredRole(let sprite, let x, let y, let role): "\(sprite) (\(x),\(y)): \(role) is not a declared role"
        case .paletteLacksRoles(let palette, let roles): "palette \(palette) lacks roles used: \(roles)"
        case .missingAnimation(let name): "animation \(name.rawValue) missing"
        case .animationWithoutFrames(let name): "animation \(name): needs >= 1 frame"
        case .animationUnknownFrame(let name, let frame): "animation \(name): frame \(frame) does not exist"
        case .animationFps(let name): "animation \(name): fps outside 0.5-12"
        case .stillMissing(let pose): "still: no frame for pose \(pose.rawValue)"
        case .stillUnknownFrame(let pose, let frame): "still \(pose.rawValue): frame \(frame) does not exist"
        }
    }
}

/// What breaks an event's contract (notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30
/// (events)"). It costs that event, never the pet.
enum PetEventIssue: Equatable, Sendable, CustomStringConvertible {
    /// `events` is there and is not a list.
    case notAList
    case notAnObject
    case noID
    case duplicateID
    /// fps is not a number from 4 to 12.
    case fps
    case paletteNotObject
    /// A palette key other than x y z u v.
    case propRole(String)
    /// A prop role one of the animal's palettes already uses.
    case propCollides(String)
    case propColour(String)
    case noFrames
    case tooManyFrames(Int)
    /// A frame that is not 35 rows of 35 beads.
    case frameShape(String)
    /// Roles the frames paint that this palette, with the event's props, has no colour for.
    case paletteLacksRoles(palette: String, roles: String)
    case noSteps
    case stepUnknownFrame(step: Int, frame: String)
    /// A dx or dy that is not a whole number within `PetContract.eventMaxDelta`.
    case stepDelta(step: Int)
    case notBalanced(dx: Int, dy: Int)
    case liftTooHigh(Int)
    case driftTooFar(Int)
    case duration(TimeInterval)

    var description: String {
        switch self {
        case .notAList: "events is not a list"
        case .notAnObject: "not an object"
        case .noID: "no id"
        case .duplicateID: "id used twice"
        case .fps: "fps outside 4-12"
        case .paletteNotObject: "palette is not an object"
        case .propRole(let role): "palette role \(role) is not one of x y z u v"
        case .propCollides(let role): "palette role \(role) is already one of the animal's roles"
        case .propColour(let role): "palette role \(role) colour is not #rrggbb"
        case .noFrames: "frames empty"
        case .tooManyFrames(let count): "\(count) frames, at most \(PetContract.eventMaxFrames)"
        case .frameShape(let frame): "frame \(frame) is not \(PetContract.size) x \(PetContract.size)"
        case .paletteLacksRoles(let palette, let roles): "palette \(palette) lacks roles used: \(roles)"
        case .noSteps: "steps empty"
        case .stepUnknownFrame(let step, let frame): "step \(step): frame \(frame) does not exist"
        case .stepDelta(let step): "step \(step): dx or dy is not a whole number within \(PetContract.eventMaxDelta)"
        case .notBalanced(let dx, let dy): "deltas sum to \(dx), \(dy), not 0, 0"
        case .liftTooHigh(let beads): "lift \(beads) beads, at most \(PetContract.eventMaxLift)"
        case .driftTooFar(let beads): "drift \(beads) beads, at most \(PetContract.eventMaxDrift)"
        case .duration(let seconds): "lasts \(seconds) s, outside 1.5-8"
        }
    }
}

/// What the check reports without failing the manifest.
enum PetManifestNote: Equatable, Sendable, CustomStringConvertible {
    /// Roles a palette declares that no frame and not the ear uses, sorted ("3w").
    case unusedRoles(String)
    /// An event left out, by its id ("#2" by its place when it has none), and why.
    case eventDropped(id: String, issues: [PetEventIssue])

    var isDroppedEvent: Bool {
        if case .eventDropped = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .unusedRoles(let roles): "roles declared but unused: \(roles)"
        case .eventDropped(let id, let issues):
            "event \(id) dropped: \(issues.map(\.description).joined(separator: "; "))"
        }
    }
}

/// One folder's check: its issues, its notes, and the pet when there is no issue.
struct PetManifestCheck: Equatable, Sendable {
    let issues: [PetManifestIssue]
    let notes: [PetManifestNote]
    /// Non-nil exactly when `issues` is empty.
    let manifest: PetManifest?
}

/// The manifest contract check (notch-island spec 2026-10-29 § 3.5 "Manifest contract", § 3.9
/// "Manifest validation"): the checks P4's art validator made, in the same order, so the
/// library admits only complete pets and the bundle test holds the shipped ones to it. Roles
/// and row widths count Unicode scalars, as the art validator counts code points. Not here:
/// the contrast lines (information for the artist) and the roster (which palettes each animal
/// has), which PetBundleTests checks, so a pet folder added later needs no code. Pure.
enum PetManifestValidator {
    static func check(_ data: Data, folder: String) -> PetManifestCheck {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return PetManifestCheck(issues: [.unreadable], notes: [], manifest: nil)
        }
        let json = object as? [String: Any] ?? [:]
        var issues: [PetManifestIssue] = []

        let missing = PetContract.keys.filter { json[$0] == nil }
        let extra = json.keys
            .filter { !PetContract.keys.contains($0) && !PetContract.optionalKeys.contains($0) }
            .sorted()
        if !missing.isEmpty { issues.append(.missingKeys(missing)) }
        if !extra.isEmpty { issues.append(.extraKeys(extra)) }
        guard missing.isEmpty else { return PetManifestCheck(issues: issues, notes: [], manifest: nil) }

        if json["id"] as? String != folder {
            issues.append(.idMismatch(id: text(json["id"]), folder: folder))
        }
        let name = json["name"] as? String ?? ""
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyName)
        }
        let size = integer(json["size"])
        if size != PetContract.size { issues.append(.badSize) }
        let side = size ?? PetContract.size

        let palettes = json["palettes"] as? [String: Any] ?? [:]
        if palettes.isEmpty { issues.append(.noPalettes) }
        var declared = Set<Unicode.Scalar>()
        var paletteRoles: [String: Set<Unicode.Scalar>] = [:]
        for paletteName in palettes.keys.sorted() {
            guard let palette = palettes[paletteName] as? [String: Any] else {
                issues.append(.paletteNotObject(paletteName))
                paletteRoles[paletteName] = []
                continue
            }
            paletteRoles[paletteName] = Set(palette.keys.compactMap { singleScalar($0) })
            for role in palette.keys.sorted() {
                if role == String(PetContract.transparent) {
                    issues.append(.transparentRole(palette: paletteName))
                } else if let scalar = singleScalar(role) {
                    declared.insert(scalar)
                } else {
                    issues.append(.roleNotOneCharacter(palette: paletteName, role: role))
                }
                if (palette[role] as? String).flatMap(PetRGB.init(hex:)) == nil {
                    issues.append(.badColour(palette: paletteName, role: role))
                }
            }
        }

        let frames = json["frames"] as? [String: Any] ?? [:]
        if frames.isEmpty { issues.append(.noFrames) }
        var used = Set<Unicode.Scalar>()
        for frameName in frames.keys.sorted() {
            used.formUnion(checkMap(frames[frameName], sprite: .frame(frameName), side: side, declared: declared, issues: &issues))
        }
        used.formUnion(checkMap(json["ear"], sprite: .ear, side: PetContract.earSize, declared: declared, issues: &issues))
        for paletteName in palettes.keys.sorted() {
            let lacking = used.subtracting(paletteRoles[paletteName] ?? [])
            if !lacking.isEmpty {
                issues.append(.paletteLacksRoles(palette: paletteName, roles: roleList(lacking)))
            }
        }
        let unused = declared.subtracting(used)
        let notes: [PetManifestNote] = unused.isEmpty ? [] : [.unusedRoles(roleList(unused))]

        let animations = json["animations"] as? [String: Any] ?? [:]
        for name in PetAnimationName.allCases where animations[name.rawValue] == nil {
            issues.append(.missingAnimation(name))
        }
        for animationName in animations.keys.sorted() {
            let spec = animations[animationName] as? [String: Any]
            let list = spec?["frames"] as? [Any] ?? []
            if list.isEmpty { issues.append(.animationWithoutFrames(animationName)) }
            for frame in list where (frame as? String).map({ frames[$0] != nil }) != true {
                issues.append(.animationUnknownFrame(animation: animationName, frame: text(frame)))
            }
            if number(spec?["fps"]).map({ PetContract.fps.contains($0) }) != true {
                issues.append(.animationFps(animationName))
            }
        }

        let still = json["still"] as? [String: Any] ?? [:]
        for pose in PetPose.allCases {
            guard let value = still[pose.rawValue] else {
                issues.append(.stillMissing(pose))
                continue
            }
            if (value as? String).map({ frames[$0] != nil }) != true {
                issues.append(.stillUnknownFrame(pose, frame: text(value)))
            }
        }

        guard issues.isEmpty else { return PetManifestCheck(issues: issues, notes: notes, manifest: nil) }
        let events = checkEvents(json["events"], paletteRoles: paletteRoles)
        guard let pet = build(json, events: events.kept) else {
            return PetManifestCheck(issues: [.unreadable], notes: notes, manifest: nil)
        }
        return PetManifestCheck(issues: [], notes: notes + events.notes, manifest: pet)
    }

    // MARK: - Events

    /// The events that keep the contract, in order, and a note for each that does not: a bad event
    /// costs only itself, as a bad pet costs only itself in the library. Missing `events` is none.
    private static func checkEvents(
        _ value: Any?, paletteRoles: [String: Set<Unicode.Scalar>]
    ) -> (kept: [PetEvent], notes: [PetManifestNote]) {
        guard let value else { return ([], []) }
        guard let list = value as? [Any] else {
            return ([], [.eventDropped(id: "events", issues: [.notAList])])
        }
        var kept: [PetEvent] = []
        var notes: [PetManifestNote] = []
        var seen = Set<String>()
        let furRoles = paletteRoles.values.reduce(into: Set<Unicode.Scalar>()) { $0.formUnion($1) }
        for (index, entry) in list.enumerated() {
            guard let object = entry as? [String: Any] else {
                notes.append(.eventDropped(id: "#\(index)", issues: [.notAnObject]))
                continue
            }
            var issues: [PetEventIssue] = []
            let id = object["id"] as? String ?? ""
            let named = !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !named {
                issues.append(.noID)
            } else if seen.contains(id) {
                issues.append(.duplicateID)
            }
            let fps = number(object["fps"]).flatMap { PetContract.eventFPS.contains($0) ? $0 : nil }
            if fps == nil { issues.append(.fps) }
            let props = eventPalette(object["palette"], furRoles: furRoles, issues: &issues)
            let frames = eventFrames(
                object["frames"], props: props.declared, paletteRoles: paletteRoles, issues: &issues
            )
            let frameKeys = Set((object["frames"] as? [String: Any] ?? [:]).keys)
            let steps = eventSteps(object["steps"], frameKeys: frameKeys, issues: &issues)
            if let fps, !steps.isEmpty {
                let seconds = Double(steps.count) / fps
                if !PetContract.eventDuration.contains(seconds) { issues.append(.duration(seconds)) }
            }
            if issues.isEmpty, let fps {
                seen.insert(id)
                kept.append(PetEvent(id: id, fps: fps, frames: frames, steps: steps, palette: props.colours))
            } else {
                notes.append(.eventDropped(id: named ? id : "#\(index)", issues: issues))
            }
        }
        return (kept, notes)
    }

    /// The props' colours and the roles declared. No palette is no props. A role outside x y z u v,
    /// or one a palette of the animal already uses, is refused: fur stays fur, so every colourway
    /// keeps working.
    private static func eventPalette(
        _ value: Any?, furRoles: Set<Unicode.Scalar>, issues: inout [PetEventIssue]
    ) -> (colours: [Unicode.Scalar: PetRGB], declared: Set<Unicode.Scalar>) {
        guard let value else { return ([:], []) }
        guard let palette = value as? [String: Any] else {
            issues.append(.paletteNotObject)
            return ([:], [])
        }
        var colours: [Unicode.Scalar: PetRGB] = [:]
        var declared = Set<Unicode.Scalar>()
        for role in palette.keys.sorted() {
            guard let scalar = singleScalar(role), PetContract.eventPropRoles.contains(scalar) else {
                issues.append(.propRole(role))
                continue
            }
            declared.insert(scalar)
            if furRoles.contains(scalar) {
                issues.append(.propCollides(role))
                continue
            }
            if let colour = (palette[role] as? String).flatMap(PetRGB.init(hex:)) {
                colours[scalar] = colour
            } else {
                issues.append(.propColour(role))
            }
        }
        return (colours, declared)
    }

    /// The frames of the right shape; reports the wrong ones, too many, and any role some palette
    /// has no colour for with `props` merged.
    private static func eventFrames(
        _ value: Any?, props: Set<Unicode.Scalar>, paletteRoles: [String: Set<Unicode.Scalar>],
        issues: inout [PetEventIssue]
    ) -> [String: PetCharMap] {
        let rows = value as? [String: Any] ?? [:]
        if rows.isEmpty { issues.append(.noFrames) }
        if rows.count > PetContract.eventMaxFrames { issues.append(.tooManyFrames(rows.count)) }
        var frames: [String: PetCharMap] = [:]
        for name in rows.keys.sorted() {
            guard let lines = rows[name] as? [String],
                  let map = PetCharMap(rows: lines, side: PetContract.size)
            else {
                issues.append(.frameShape(name))
                continue
            }
            frames[name] = map
        }
        let used = frames.values.reduce(into: Set<Unicode.Scalar>()) { $0.formUnion($1.roles) }
        for palette in paletteRoles.keys.sorted() {
            let lacking = used.subtracting(paletteRoles[palette] ?? []).subtracting(props)
            if !lacking.isEmpty {
                issues.append(.paletteLacksRoles(palette: palette, roles: roleList(lacking)))
            }
        }
        return frames
    }

    /// The steps; reports an unknown frame, a delta that is not whole, and, when every delta is
    /// whole, deltas that do not sum to zero or go past the lift and drift limits (the peak above
    /// the floor, the farthest from the start). An omitted delta is 0.
    private static func eventSteps(
        _ value: Any?, frameKeys: Set<String>, issues: inout [PetEventIssue]
    ) -> [PetEventStep] {
        guard let list = value as? [Any], !list.isEmpty else {
            issues.append(.noSteps)
            return []
        }
        var steps: [PetEventStep] = []
        var whole = true
        for (index, entry) in list.enumerated() {
            let object = entry as? [String: Any] ?? [:]
            let frame = object["f"] as? String
            if frame.map({ !frameKeys.contains($0) }) ?? true {
                issues.append(.stepUnknownFrame(step: index, frame: text(object["f"])))
            }
            let dx = delta(object["dx"])
            let dy = delta(object["dy"])
            if dx == nil || dy == nil {
                issues.append(.stepDelta(step: index))
                whole = false
            }
            steps.append(PetEventStep(frame: frame ?? "", dx: dx ?? 0, dy: dy ?? 0))
        }
        guard whole else { return steps }
        var x = 0
        var y = 0
        var lift = 0
        var drift = 0
        for step in steps {
            x += step.dx
            y += step.dy
            lift = max(lift, -y)
            drift = max(drift, abs(x))
        }
        if x != 0 || y != 0 { issues.append(.notBalanced(dx: x, dy: y)) }
        if lift > PetContract.eventMaxLift { issues.append(.liftTooHigh(lift)) }
        if drift > PetContract.eventMaxDrift { issues.append(.driftTooFar(drift)) }
        return steps
    }

    /// A step's delta: omitted is 0; nil for anything but a whole number within the bound, checked
    /// before any sum and without `abs`, which traps on `Int.min`.
    private static func delta(_ value: Any?) -> Int? {
        guard let value else { return 0 }
        guard let beads = integer(value),
              (-PetContract.eventMaxDelta...PetContract.eventMaxDelta).contains(beads)
        else { return nil }
        return beads
    }

    // MARK: - The pet

    /// The roles a map paints; reports a wrong shape or a bead that is no declared role. A row's
    /// width is its Unicode scalars, as the art validator counts code points.
    private static func checkMap(
        _ value: Any?, sprite: PetSprite, side: Int, declared: Set<Unicode.Scalar>, issues: inout [PetManifestIssue]
    ) -> Set<Unicode.Scalar> {
        guard let rows = value as? [Any], rows.count == side else {
            issues.append(.rowCount(sprite, expected: side))
            return []
        }
        var used = Set<Unicode.Scalar>()
        for (y, entry) in rows.enumerated() {
            guard let row = entry as? String, row.unicodeScalars.count == side else {
                issues.append(.rowLength(sprite, row: y, expected: side))
                continue
            }
            for (x, bead) in row.unicodeScalars.enumerated() where bead != PetContract.transparent {
                used.insert(bead)
                if !declared.contains(bead) {
                    issues.append(.undeclaredRole(sprite, x: x, y: y, role: bead))
                }
            }
        }
        return used
    }

    /// The pet from a manifest every check above passed.
    private static func build(_ json: [String: Any], events: [PetEvent]) -> PetManifest? {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let paletteObjects = json["palettes"] as? [String: [String: String]],
              let frameRows = json["frames"] as? [String: [String]],
              let animationObjects = json["animations"] as? [String: [String: Any]],
              let stills = json["still"] as? [String: Any],
              let earRows = json["ear"] as? [String],
              let ear = PetCharMap(rows: earRows, side: PetContract.earSize)
        else { return nil }
        var palettes: [String: [Unicode.Scalar: PetRGB]] = [:]
        for (paletteName, roles) in paletteObjects {
            var colours: [Unicode.Scalar: PetRGB] = [:]
            for (role, hex) in roles {
                guard let scalar = singleScalar(role), let colour = PetRGB(hex: hex) else { return nil }
                colours[scalar] = colour
            }
            palettes[paletteName] = colours
        }
        var frames: [String: PetCharMap] = [:]
        for (frameName, rows) in frameRows {
            guard let map = PetCharMap(rows: rows, side: PetContract.size) else { return nil }
            frames[frameName] = map
        }
        func animation(_ name: PetAnimationName) -> PetAnimation? {
            guard let object = animationObjects[name.rawValue],
                  let list = object["frames"] as? [String],
                  let fps = number(object["fps"])
            else { return nil }
            return PetAnimation(frames: list, fps: fps)
        }
        guard let idle = animation(.idle),
              let blink = animation(.blink),
              let walk = animation(.walk),
              let look = animation(.look),
              let sleep = animation(.sleep),
              let stillIdle = stills[PetPose.idle.rawValue] as? String,
              let stillLook = stills[PetPose.look.rawValue] as? String,
              let stillSleep = stills[PetPose.sleep.rawValue] as? String
        else { return nil }
        return PetManifest(
            id: id,
            name: name,
            size: PetContract.size,
            palettes: palettes,
            frames: frames,
            animations: PetAnimations(idle: idle, blink: blink, walk: walk, look: look, sleep: sleep),
            still: PetStills(idle: stillIdle, look: stillLook, sleep: stillSleep),
            ear: ear,
            events: events
        )
    }

    /// A JSON number; nil for anything else, booleans included (JSONSerialization hands `true`
    /// back as an NSNumber that would read as 1).
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// A JSON number with no fraction.
    private static func integer(_ value: Any?) -> Int? {
        number(value).flatMap { Int(exactly: $0) }
    }

    /// The one Unicode scalar `role` is made of; nil for none or several.
    private static func singleScalar(_ role: String) -> Unicode.Scalar? {
        let scalars = role.unicodeScalars
        return scalars.count == 1 ? scalars.first : nil
    }

    /// Roles as one string, in code-point order ("3w"), as the art validator sorts them.
    private static func roleList(_ roles: Set<Unicode.Scalar>) -> String {
        roles.sorted().map { String($0) }.joined()
    }

    /// A JSON value as an issue quotes it.
    private static func text(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let string = value as? String { return string }
        return "\(value)"
    }
}
