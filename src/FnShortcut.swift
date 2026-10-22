import Foundation
import CoreGraphics
import Carbon

/// Atajos globales de «mantener para dictar» (Fn, ⌃⌥ izquierdos o los que
/// grabe el usuario). El event tap corre en su propio hilo, nunca en la UI.
@MainActor
final class HotkeyShortcut {
    private let onDown: @MainActor () -> Void
    private let onUp: @MainActor () -> Void
    private let onAbort: @MainActor () -> Void
    private let onStatus: @MainActor (String) -> Void
    private let onRecorded: @MainActor (HotkeyTrigger?) -> Void
    private var worker: HotkeyWorker?
    private var generation: UInt64 = 0
    private var isDown = false
    private var triggers: [HotkeyTrigger]
    private(set) var available = false

    init(triggers: [HotkeyTrigger],
         onDown: @escaping @MainActor () -> Void,
         onUp: @escaping @MainActor () -> Void,
         onAbort: @escaping @MainActor () -> Void,
         onStatus: @escaping @MainActor (String) -> Void,
         onRecorded: @escaping @MainActor (HotkeyTrigger?) -> Void) {
        self.triggers = triggers
        self.onDown = onDown
        self.onUp = onUp
        self.onAbort = onAbort
        self.onStatus = onStatus
        self.onRecorded = onRecorded
    }

    func start() {
        guard worker == nil else { refresh(); return }
        generation &+= 1
        let currentGeneration = generation
        let worker = HotkeyWorker(triggers: triggers) { [weak self] event in
            // Una única cola serie conserva el orden pulsar/soltar aunque la UI esté ocupada.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                switch event {
                case .down:
                    guard !self.isDown else { return }
                    self.isDown = true
                    self.onDown()
                case .up:
                    guard self.isDown else { return }
                    self.isDown = false
                    self.onUp()
                case .abort:
                    guard self.isDown else { return }
                    self.isDown = false
                    self.onAbort()
                case let .status(available, message):
                    self.available = available
                    self.onStatus(message)
                case let .recorded(trigger):
                    self.onRecorded(trigger)
                }
            }
        }
        self.worker = worker
        worker.start()
    }

    func stop() {
        generation &+= 1
        worker?.stop()
        worker = nil
        available = false
        if isDown {
            isDown = false
            onUp()
        }
    }

    func refresh() {
        guard let worker else { start(); return }
        worker.refresh()
    }

    func setTriggers(_ triggers: [HotkeyTrigger]) {
        self.triggers = triggers
        worker?.setTriggers(triggers)
    }

    func startRecording() { worker?.setRecording(true) }
    func cancelRecording() { worker?.setRecording(false) }

    deinit { worker?.stop() }
}

/// Todo el acceso al tap, al temporizador y al estado ocurre en el run loop de
/// este hilo. El candado solo transfiere peticiones de ciclo de vida y ajustes.
private final class HotkeyWorker: @unchecked Sendable {
    enum Event: Sendable {
        case down, up, abort
        case status(Bool, String)
        case recorded(HotkeyTrigger?)
    }

    private let deliver: @Sendable (Event) -> Void
    private let controlLock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopRequested = false
    private var refreshRequested = false
    private var requestedTriggers: [HotkeyTrigger]?
    private var requestedRecording: Bool?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var matcher: HotkeyMatcher
    private var recorder = HotkeyRecorder()
    private var recording = false
    private var fnHeld = false
    private var lastAttempt: CFAbsoluteTime = 0
    private var lastHealthCheck: CFAbsoluteTime = 0
    private var lastStatus: String?
    private var lastAvailable: Bool?
    private static let readyMessage = "Atajos listos."
    private static let unavailableMessage = "Atajos no disponibles: revisa Accesibilidad para Dictado Mac."

    init(triggers: [HotkeyTrigger], deliver: @escaping @Sendable (Event) -> Void) {
        self.matcher = HotkeyMatcher(triggers: triggers)
        self.deliver = deliver
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "DictadoMac.Hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        controlLock.lock()
        stopRequested = true
        let loop = runLoop
        controlLock.unlock()
        if let loop {
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
        }
    }

    func refresh() {
        controlLock.lock()
        refreshRequested = true
        let loop = runLoop
        controlLock.unlock()
        if let loop { CFRunLoopWakeUp(loop) }
    }

    func setTriggers(_ triggers: [HotkeyTrigger]) {
        controlLock.lock()
        requestedTriggers = triggers
        controlLock.unlock()
    }

    func setRecording(_ value: Bool) {
        controlLock.lock()
        requestedRecording = value
        controlLock.unlock()
    }

    private func run() {
        let loop = CFRunLoopGetCurrent()!
        controlLock.lock()
        runLoop = loop
        let shouldStop = stopRequested
        controlLock.unlock()
        guard !shouldStop else {
            controlLock.lock()
            runLoop = nil
            controlLock.unlock()
            return
        }
        // El temporizador mantiene vivo el run loop aunque falte el permiso,
        // así que concederlo más tarde no exige reiniciar la app.
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.02,
            0.02, 0, 0
        ) { [weak self] _ in self?.tick() }!
        CFRunLoopAddTimer(loop, timer, .commonModes)
        installTap()
        CFRunLoopRun()
        CFRunLoopTimerInvalidate(timer)
        removeTap()
        emit(matcher.reset(held: []))
        controlLock.lock()
        runLoop = nil
        controlLock.unlock()
    }

    private func installTap() {
        lastAttempt = CFAbsoluteTimeGetCurrent()
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let worker = Unmanaged<HotkeyWorker>.fromOpaque(context).takeUnretainedValue()
                // Las modificadoras solo se observan. Solo se consume la tecla
                // normal de un atajo (para que no se escriba) y lo que se graba.
                return worker.receive(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            status(false, Self.unavailableMessage)
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            status(false, "No se pudieron iniciar los atajos.")
            return
        }
        tap = newTap
        tapSource = source
        fnHeld = physicalHeld().contains(.fn)
        emit(matcher.reset(held: physicalHeld()))
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        let enabled = CGEvent.tapIsEnabled(tap: newTap)
        status(enabled, enabled ? Self.readyMessage : Self.unavailableMessage)
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tapSource, .commonModes)
            CFRunLoopSourceInvalidate(tapSource)
        }
        tapSource = nil
        tap = nil
    }

    /// Devuelve true si el evento debe consumirse.
    private func receive(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            emit(matcher.reset(held: physicalHeld()))
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                let enabled = CGEvent.tapIsEnabled(tap: tap)
                status(enabled, enabled ? "Atajos recuperados." : Self.unavailableMessage)
            }
            return false
        }
        // La inserción en vivo puede publicar teclas; no deben cortar el dictado.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return false }
        let key = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let now = CFAbsoluteTimeGetCurrent()
        switch type {
        case .flagsChanged:
            let fnFlag = event.flags.contains(.maskSecondaryFn)
            // Fn solo cuenta por su propia tecla: las flechas y teclas F también marcan el flag.
            if key == 63 { fnHeld = fnFlag } else if !fnFlag { fnHeld = false }
            let held = ModifierSet.from(eventFlags: event.flags.rawValue, fnHeld: fnHeld)
            if recording {
                if let trigger = recorder.modifiersChanged(held) { finishRecording(trigger) }
                return false
            }
            emit(matcher.modifiersChanged(held, at: now))
            return false
        case .keyDown:
            let held = ModifierSet.from(eventFlags: event.flags.rawValue, fnHeld: fnHeld)
            if recording {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
                if key == 53 && held.isEmpty { finishRecording(nil) } else {
                    finishRecording(recorder.keyDown(key, held: held))
                }
                return true
            }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let (output, consume) = matcher.keyDown(key, isRepeat: isRepeat, at: now)
            emit(output)
            return consume
        case .keyUp:
            if recording { return true }
            let (output, consume) = matcher.keyUp(key)
            emit(output)
            return consume
        default:
            return false
        }
    }

    private func finishRecording(_ trigger: HotkeyTrigger?) {
        recording = false
        recorder = HotkeyRecorder()
        emit(matcher.reset(held: physicalHeld()))
        deliver(.recorded(trigger))
    }

    private func tick() {
        controlLock.lock()
        let shouldStop = stopRequested
        let shouldRefresh = refreshRequested
        refreshRequested = false
        let newTriggers = requestedTriggers
        requestedTriggers = nil
        let newRecording = requestedRecording
        requestedRecording = nil
        controlLock.unlock()
        if shouldStop {
            CFRunLoopStop(CFRunLoopGetCurrent())
            return
        }
        if let newTriggers {
            matcher.triggers = newTriggers
            emit(matcher.reset(held: physicalHeld()))
        }
        if let newRecording, newRecording != recording {
            if newRecording {
                emit(matcher.reset(held: []))
                recorder = HotkeyRecorder()
                recording = true
            } else {
                recording = false
                emit(matcher.reset(held: physicalHeld()))
            }
        }
        let now = CFAbsoluteTimeGetCurrent()
        if !recording {
            // Conciliación de liberaciones perdidas: nunca empieza una pulsación
            // a partir del estado muestreado, solo la termina.
            let physical = physicalHeld()
            if !physical.contains(.fn) { fnHeld = false }
            if !matcher.held.isSubset(of: physical) {
                emit(matcher.modifiersChanged(matcher.held.intersection(physical), at: now))
            }
            if let key = matcher.swallowedKey,
               !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key)) {
                emit(matcher.keyUp(key).0)
            }
            emit(matcher.tick(at: now))
        }
        guard shouldRefresh || now - lastHealthCheck >= 0.75 else { return }
        lastHealthCheck = now
        if let tap, CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) {
                emit(matcher.reset(held: physicalHeld()))
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            let enabled = CGEvent.tapIsEnabled(tap: tap)
            status(enabled, enabled ? Self.readyMessage : Self.unavailableMessage)
        } else if shouldRefresh || now - lastAttempt >= 2 {
            removeTap()
            emit(matcher.reset(held: physicalHeld()))
            installTap()
        }
    }

    private func physicalHeld() -> ModifierSet {
        var set: ModifierSet = []
        for info in ModifierSet.all where CGEventSource.keyState(.hidSystemState, key: CGKeyCode(info.keyCode)) {
            set.insert(info.modifier)
        }
        if CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) { set.insert(.fn) }
        return set
    }

    private func emit(_ outputs: [HotkeyMatcher.Output]) {
        for output in outputs {
            switch output {
            case .down: deliver(.down)
            case .up: deliver(.up)
            case .abort: deliver(.abort)
            }
        }
    }

    private func status(_ available: Bool, _ message: String) {
        guard lastStatus != message || lastAvailable != available else { return }
        lastStatus = message
        lastAvailable = available
        deliver(.status(available, message))
    }
}

/// Nombre visible de una tecla según la distribución de teclado activa.
@MainActor
enum KeyNames {
    static func name(_ code: UInt16) -> String {
        if let special = HotkeyTrigger.specialKeyNames[code] { return special }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Tecla \(code)"
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let result = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                  characters.count, &length, &characters)
        }
        guard result == noErr, length > 0 else { return "Tecla \(code)" }
        let text = String(utf16CodeUnits: characters, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Tecla \(code)" : text.uppercased()
    }
}
