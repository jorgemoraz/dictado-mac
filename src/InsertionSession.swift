import AppKit
import ApplicationServices
import Carbon
import Foundation

// Inserción al estilo de Wispr Flow / VoiceInk / Superwhisper:
// 1. Se guarda el portapapeles.
// 2. Se pone el texto dictado (marcado como transitorio para gestores de portapapeles).
// 3. Se envía un ⌘V real al flujo de eventos del sistema (HID), que llega a la app
//    y al campo que tienen el foco en ese momento, igual que si lo pulsaras tú.
// 4. Se restaura el portapapeles cuando el destino ya lo ha leído.
//
// La versión 4 exigía leer y verificar por Accesibilidad el contenido y el cursor
// del campo antes y después de cada paso. Chrome, Safari, Electron (Slack, WhatsApp,
// Teams, Claude, ChatGPT…), Word y muchos editores web no exponen esos datos o
// tardan más de 70 ms en responder, y entonces la app abortaba sin pegar.
// Además enviaba ⌘V con postToPid, que muchas apps ignoran.

enum InsertionOutcome: Sendable {
    case pasted(String)
    case typed(String)
    case skipped(String)
    case failed(String)

    var message: String {
        switch self {
        case .pasted(let app): return "Texto pegado en \(app)."
        case .typed(let app): return "Texto escrito en \(app)."
        case .skipped(let reason), .failed(let reason): return reason
        }
    }
    var inserted: Bool {
        switch self { case .pasted, .typed: return true; default: return false }
    }
}

private enum InsertionLog {
    private static let queue = DispatchQueue(label: "DictadoMac.insertion.log", qos: .utility)
    // Solo metadatos: nunca se registra el texto dictado ni el portapapeles.
    static func note(_ event: String) {
        queue.async {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DictadoMac")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("insertion.log")
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
               size.intValue > 65_536 { try? Data().write(to: file) }
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\(Date().timeIntervalSince1970) \(event)\n".utf8))
        }
    }
}

@MainActor enum TextInserter {
    /// App que tiene el foco al empezar a dictar (solo para informar en la interfaz).
    static func frontmostTargetName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app.localizedName ?? "la app activa"
    }

    /// Inserta en el campo que tiene el foco AHORA (como el dictado nativo y Wispr Flow).
    static func insert(_ raw: String) async -> InsertionOutcome {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .skipped("Sin texto dictado.") }
        guard AXIsProcessTrusted() else {
            return .failed("Falta el permiso de Accesibilidad: el texto queda en Dictado Mac.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .failed("No hay ninguna app activa; el texto queda en Dictado Mac.")
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .skipped("Dictado dentro de la app. Pulsa Copiar para usarlo en otro sitio.")
        }
        let appName = app.localizedName ?? "la app activa"

        let context = FocusContext.read(pid: app.processIdentifier)
        if context.isSecure {
            InsertionLog.note("skip secure pid=\(app.processIdentifier)")
            return .skipped("No se dicta en campos de contraseña; el texto queda en Dictado Mac.")
        }
        let finalText = context.needsLeadingSpace(before: text) ? " " + text : text

        if Paste.canPostEvents {
            let ok = await Paste.paste(finalText)
            InsertionLog.note("paste pid=\(app.processIdentifier) len=\((finalText as NSString).length) ok=\(ok)")
            if ok { return .pasted(appName) }
        }
        // Último recurso: escritura directa por Accesibilidad (apps Cocoa nativas).
        if let element = context.element, FocusContext.setSelectedText(finalText, on: element) {
            InsertionLog.note("ax-insert pid=\(app.processIdentifier)")
            return .typed(appName)
        }
        return .failed("macOS no ha permitido pegar. Revisa Accesibilidad para Dictado Mac; el texto queda en la app.")
    }
}

// MARK: - Contexto del campo (mejor esfuerzo, nunca bloquea la inserción)

private struct FocusContext {
    var element: AXUIElement?
    var isSecure = false
    var previousCharacter: Character?

    static func read(pid: pid_t) -> FocusContext {
        var context = FocusContext()
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        // Activa el árbol de Accesibilidad de Chromium/Electron si estaba dormido.
        _ = copy(kAXRoleAttribute, of: application)
        let focused = element(copy(kAXFocusedUIElementAttribute, of: application))
            ?? element(copy(kAXFocusedUIElementAttribute, of: system))
        guard let focused else { return context }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        context.element = focused
        if let subrole = copy(kAXSubroleAttribute, of: focused) as? String, subrole == kAXSecureTextFieldSubrole {
            context.isSecure = true
            return context
        }
        if (copy("AXProtectedContent", of: focused) as? Bool) == true {
            context.isSecure = true
            return context
        }
        context.previousCharacter = previousCharacter(in: focused)
        return context
    }

    func needsLeadingSpace(before text: String) -> Bool {
        guard let previous = previousCharacter, let first = text.first else { return false }
        if previous.isWhitespace || "([{¿¡\"'«“‘/-".contains(previous) { return false }
        return first.isLetter || first.isNumber || first == "¿" || first == "¡"
    }

    static func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private static func previousCharacter(in element: AXUIElement) -> Character? {
        guard let rangeValue = copy(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &range),
              range.location > 0 else { return nil }
        var previous = CFRange(location: range.location - 1, length: 1)
        if let parameter = AXValueCreate(.cfRange, &previous) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                          parameter, &value) == .success,
               let string = value as? String, let last = string.last {
                return last
            }
        }
        if let full = copy(kAXValueAttribute, of: element) as? String {
            let ns = full as NSString
            guard range.location <= ns.length else { return nil }
            return (ns.substring(to: range.location)).last
        }
        return nil
    }

    private static func copy(_ attribute: String, of object: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(object, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

// MARK: - Portapapeles + ⌘V

@MainActor private enum Paste {
    static var canPostEvents: Bool { CGPreflightPostEventAccess() || AXIsProcessTrusted() }

    static func paste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let backup = pasteboard.pasteboardItems?.map { item -> [(NSPasteboard.PasteboardType, Data)] in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Convención nspasteboard.org: los gestores de portapapeles no lo guardan en el historial.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        guard pasteboard.writeObjects([item]) else {
            restore(backup, onto: pasteboard)
            return false
        }
        let ownChange = pasteboard.changeCount

        // Margen para que el cambio de portapapeles sea visible y Fn esté totalmente soltada.
        try? await Task.sleep(for: .milliseconds(40))
        let posted = postCommandV()

        // Apps Electron y web leen el portapapeles de forma asíncrona: esperar antes de restaurar.
        try? await Task.sleep(for: .milliseconds(posted ? 450 : 0))
        if pasteboard.changeCount == ownChange { restore(backup, onto: pasteboard) }
        return posted
    }

    private static func restore(_ backup: [[(NSPasteboard.PasteboardType, Data)]], onto pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = backup.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Secuencia completa de teclas (⌘ abajo, V abajo, V arriba, ⌘ arriba) enviada al
    /// flujo HID, como hacen Wispr Flow, Maccy o Raycast. Llega al campo con foco.
    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Que una tecla física pulsada en ese instante no se mezcle con el atajo.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        let command = CGKeyCode(kVK_Command)
        let v = keyCode(for: "v")
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false)
        else { return false }
        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.flags = []
        for event in [commandDown, vDown, vUp, commandUp] {
            event.post(tap: .cghidEventTap)
            usleep(6_000)
        }
        return true
    }

    /// Código de tecla que produce `character` en la distribución activa (QWERTY español,
    /// Dvorak, etc.). Si no se puede determinar, se usa la posición ANSI de la V.
    private static func keyCode(for character: Character) -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let target = character.unicodeScalars.first?.value,
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, characters.count, &length, &characters)
                if status == noErr, length == 1, UInt32(characters[0]) == target { return CGKeyCode(code) }
            }
            return fallback
        }
    }
}
