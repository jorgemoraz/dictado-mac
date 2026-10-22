import Foundation

/// Teclas modificadoras, distinguiendo el lado izquierdo del derecho.
struct ModifierSet: OptionSet, Hashable, Codable, Sendable {
    let rawValue: UInt16
    init(rawValue: UInt16) { self.rawValue = rawValue }

    static let fn = ModifierSet(rawValue: 1 << 0)
    static let leftControl = ModifierSet(rawValue: 1 << 1)
    static let rightControl = ModifierSet(rawValue: 1 << 2)
    static let leftOption = ModifierSet(rawValue: 1 << 3)
    static let rightOption = ModifierSet(rawValue: 1 << 4)
    static let leftCommand = ModifierSet(rawValue: 1 << 5)
    static let rightCommand = ModifierSet(rawValue: 1 << 6)
    static let leftShift = ModifierSet(rawValue: 1 << 7)
    static let rightShift = ModifierSet(rawValue: 1 << 8)

    struct Info: Sendable {
        let modifier: ModifierSet
        let label: String
        let keyCode: UInt16
    }

    /// Orden de presentación y código de tecla físico de cada modificadora.
    static let all: [Info] = [
        Info(modifier: .fn, label: "Fn", keyCode: 63),
        Info(modifier: .leftControl, label: "⌃ izq.", keyCode: 59),
        Info(modifier: .rightControl, label: "⌃ dcha.", keyCode: 62),
        Info(modifier: .leftOption, label: "⌥ izq.", keyCode: 58),
        Info(modifier: .rightOption, label: "⌥ dcha.", keyCode: 61),
        Info(modifier: .leftCommand, label: "⌘ izq.", keyCode: 55),
        Info(modifier: .rightCommand, label: "⌘ dcha.", keyCode: 54),
        Info(modifier: .leftShift, label: "⇧ izq.", keyCode: 56),
        Info(modifier: .rightShift, label: "⇧ dcha.", keyCode: 60),
    ]

    static func isModifierKey(_ keyCode: UInt16) -> Bool {
        all.contains { $0.keyCode == keyCode }
    }

    /// Lee los bits por dispositivo de CGEventFlags (NX_DEVICE*KEYMASK).
    /// Si una herramienta de remapeo no los rellena, se asume el lado izquierdo.
    static func from(eventFlags raw: UInt64, fnHeld: Bool) -> ModifierSet {
        var set: ModifierSet = fnHeld ? .fn : []
        let device: [(UInt64, ModifierSet)] = [
            (0x0000_0001, .leftControl), (0x0000_2000, .rightControl),
            (0x0000_0020, .leftOption), (0x0000_0040, .rightOption),
            (0x0000_0008, .leftCommand), (0x0000_0010, .rightCommand),
            (0x0000_0002, .leftShift), (0x0000_0004, .rightShift),
        ]
        for (mask, modifier) in device where raw & mask != 0 { set.insert(modifier) }
        let generic: [(UInt64, ModifierSet, ModifierSet)] = [
            (0x0004_0000, [.leftControl, .rightControl], .leftControl),
            (0x0008_0000, [.leftOption, .rightOption], .leftOption),
            (0x0010_0000, [.leftCommand, .rightCommand], .leftCommand),
            (0x0002_0000, [.leftShift, .rightShift], .leftShift),
        ]
        for (mask, either, fallback) in generic where raw & mask != 0 && set.isDisjoint(with: either) {
            set.insert(fallback)
        }
        return set
    }
}

/// Un atajo para dictar mientras se mantiene pulsado: solo modificadoras
/// (p. ej. Fn, o ⌃+⌥ izquierdos) o modificadoras más una tecla.
struct HotkeyTrigger: Codable, Hashable, Sendable, Identifiable {
    var modifiers: ModifierSet
    var key: UInt16?

    var id: String { "\(modifiers.rawValue)-\(key.map { String($0) } ?? "x")" }
    var isModifierOnly: Bool { key == nil }

    static let fn = HotkeyTrigger(modifiers: .fn, key: nil)
    static let leftControlOption = HotkeyTrigger(modifiers: [.leftControl, .leftOption], key: nil)
    static let defaults: [HotkeyTrigger] = [.fn, .leftControlOption]

    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                            105, 107, 113, 106, 64, 79, 80, 90]
    static let specialKeyNames: [UInt16: String] = [
        49: "Espacio", 36: "Intro", 76: "Intro", 48: "Tab", 51: "Borrar", 117: "Supr", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Inicio", 119: "Fin", 116: "RePág", 121: "AvPág",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    func label(keyName: (UInt16) -> String) -> String {
        var parts = ModifierSet.all.filter { modifiers.contains($0.modifier) }.map(\.label)
        if let key { parts.append(keyName(key)) }
        return parts.joined(separator: " + ")
    }

    /// Motivo por el que no conviene usar este atajo, o nil si es válido.
    var problem: String? {
        if modifiers.isEmpty && key == nil { return "No se ha detectado ninguna tecla." }
        if let key, modifiers.isEmpty, !Self.functionKeys.contains(key) {
            return "Una tecla normal sola dejaría de escribirse. Combínala con una modificadora o usa una tecla F."
        }
        return nil
    }
}

/// Lógica pura de «mantener para dictar», separada del event tap para poder
/// probarla sin teclado ni permisos.
struct HotkeyMatcher {
    enum Output: Equatable { case down, up, abort }

    /// Las combinaciones solo de modificadoras (salvo Fn) esperan un instante
    /// para no dispararse al usar atajos como ⌃⌥Espacio.
    static let armDelay: TimeInterval = 0.15
    /// Si otra tecla llega tan pronto, no era un dictado: se descarta.
    static let abortWindow: TimeInterval = 0.6

    var triggers: [HotkeyTrigger]
    private(set) var held: ModifierSet = []
    private(set) var active: HotkeyTrigger?
    private(set) var swallowedKey: UInt16?
    private var activeSince: TimeInterval = 0
    private var pending: HotkeyTrigger?
    private var pendingSince: TimeInterval = 0
    private var blocked = false

    init(triggers: [HotkeyTrigger]) { self.triggers = triggers }

    var isHolding: Bool { active != nil }

    /// Al (re)instalar el tap a mitad de una pulsación nunca se empieza a grabar.
    mutating func reset(held: ModifierSet) -> [Output] {
        let output: [Output] = active != nil ? [.up] : []
        active = nil
        pending = nil
        swallowedKey = nil
        self.held = held
        blocked = !held.isEmpty
        return output
    }

    mutating func modifiersChanged(_ newHeld: ModifierSet, at time: TimeInterval) -> [Output] {
        held = newHeld
        pending = nil
        if let current = active {
            if newHeld == current.modifiers { return [] }
            active = nil
            blocked = !newHeld.isEmpty
            // Añadir otra modificadora es un atajo distinto; soltar una, terminar.
            return [newHeld.isStrictSuperset(of: current.modifiers) ? chordEnd(at: time) : .up]
        }
        if newHeld.isEmpty { blocked = false; return [] }
        guard !blocked,
              let match = triggers.first(where: { $0.isModifierOnly && $0.modifiers == newHeld }) else { return [] }
        if match.modifiers == .fn { return activate(match, at: time) }
        pending = match
        pendingSince = time
        return []
    }

    mutating func tick(at time: TimeInterval) -> [Output] {
        guard let candidate = pending, !blocked, held == candidate.modifiers,
              time - pendingSince >= Self.armDelay else { return [] }
        pending = nil
        return activate(candidate, at: time)
    }

    /// Devuelve las transiciones y si el evento debe consumirse.
    mutating func keyDown(_ key: UInt16, isRepeat: Bool, at time: TimeInterval) -> ([Output], Bool) {
        if swallowedKey == key { return ([], true) }
        if active != nil {
            active = nil
            blocked = !held.isEmpty
            return ([chordEnd(at: time)], false)
        }
        if pending != nil {
            pending = nil
            blocked = true
            return ([], false)
        }
        guard !isRepeat,
              let match = triggers.first(where: { $0.key == key && $0.modifiers == held }) else { return ([], false) }
        swallowedKey = key
        return (activate(match, at: time), true)
    }

    mutating func keyUp(_ key: UInt16) -> ([Output], Bool) {
        guard swallowedKey == key else { return ([], false) }
        swallowedKey = nil
        if let current = active, current.key == key {
            active = nil
            blocked = !held.isEmpty
            return ([.up], true)
        }
        return ([], true)
    }

    private mutating func activate(_ trigger: HotkeyTrigger, at time: TimeInterval) -> [Output] {
        active = trigger
        activeSince = time
        return [.down]
    }

    private func chordEnd(at time: TimeInterval) -> Output {
        time - activeSince < Self.abortWindow ? .abort : .up
    }
}

/// Graba una combinación: la tecla normal pulsada, o el conjunto máximo de
/// modificadoras mantenidas al soltarlas todas.
struct HotkeyRecorder {
    private(set) var peak: ModifierSet = []

    mutating func modifiersChanged(_ held: ModifierSet) -> HotkeyTrigger? {
        if held.isEmpty {
            defer { peak = [] }
            return peak.isEmpty ? nil : HotkeyTrigger(modifiers: peak, key: nil)
        }
        peak.formUnion(held)
        return nil
    }

    mutating func keyDown(_ key: UInt16, held: ModifierSet) -> HotkeyTrigger {
        peak = []
        return HotkeyTrigger(modifiers: held, key: key)
    }
}
