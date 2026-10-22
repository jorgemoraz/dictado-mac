import AppKit
import ApplicationServices
import Foundation

/// Estilo de puntuación según dónde estás escribiendo.
enum WritingMode: String, CaseIterable, Sendable, Identifiable {
    case formal, neutral, informal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .formal: return "Formal"
        case .neutral: return "Neutro"
        case .informal: return "Informal"
        }
    }
    var detail: String {
        switch self {
        case .formal: return "Puntuación completa: ¿…?, ¡…!, mayúscula inicial y punto final."
        case .neutral: return "Puntuación tal como la da macOS."
        case .informal: return "Chat: sin ¿ ni ¡ de apertura y sin punto final."
        }
    }
}

struct StyleTarget: Sendable, Equatable {
    let appName: String
    let bundleID: String
    let windowTitle: String
    var isBrowser: Bool { WritingStyle.browsers.contains(bundleID) }
}

@MainActor enum WritingStyle {
    nonisolated static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "ai.perplexity.comet", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "app.zen-browser.zen", "com.openai.atlas"
    ]

    // Apps de escritorio, por nombre visible (más estable que el identificador entre versiones).
    private static let formalApps = ["Mail", "Correo", "Outlook", "Microsoft Outlook", "Spark", "Airmail",
                                     "Superhuman", "Mimestream", "Thunderbird", "Microsoft Word", "Pages", "Canary Mail"]
    private static let informalApps = ["WhatsApp", "Telegram", "Mensajes", "Messages", "Slack", "Discord",
                                       "Microsoft Teams", "Signal", "ChatGPT", "Claude", "Perplexity", "Grok",
                                       "Grok Bot", "Gemini", "LM Studio", "Ollama", "Codex", "Messenger"]
    // Pestañas del navegador, por título de la ventana activa.
    private static let formalTitles = ["Gmail", "Outlook", "Correo", "Proton Mail", "Yahoo Mail", "iCloud Mail",
                                       "Redactar", "Compose", "Nuevo mensaje", "New Message"]
    private static let informalTitles = ["ChatGPT", "Claude", "WhatsApp", "Gemini", "Perplexity", "Grok",
                                         "Telegram", "Slack", "Discord", "Messenger", "Teams", "Copilot", "DeepSeek"]

    static func currentTarget() -> StyleTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return StyleTarget(appName: app.localizedName ?? "",
                           bundleID: app.bundleIdentifier ?? "",
                           windowTitle: windowTitle(pid: app.processIdentifier))
    }

    /// Clave para recordar tu elección: la app, o la app + sitio en navegadores.
    static func overrideKey(for target: StyleTarget) -> String {
        guard target.isBrowser, let site = site(in: target.windowTitle) else { return target.appName }
        return "\(target.appName) · \(site)"
    }

    static func detect(_ target: StyleTarget, overrides: [String: String]) -> WritingMode {
        if let saved = overrides[overrideKey(for: target)], let mode = WritingMode(rawValue: saved) { return mode }
        if target.isBrowser {
            if contains(target.windowTitle, any: informalTitles) { return .informal }
            if contains(target.windowTitle, any: formalTitles) { return .formal }
            return .neutral
        }
        if informalApps.contains(where: { $0.caseInsensitiveCompare(target.appName) == .orderedSame }) { return .informal }
        if formalApps.contains(where: { $0.caseInsensitiveCompare(target.appName) == .orderedSame }) { return .formal }
        return .neutral
    }

    private static func site(in title: String) -> String? {
        (informalTitles + formalTitles).first { title.localizedCaseInsensitiveContains($0) }
    }

    private static func contains(_ title: String, any words: [String]) -> Bool {
        words.contains { title.localizedCaseInsensitiveContains($0) }
    }

    private static func windowTitle(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return "" }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(unsafeDowncast(window, to: AXUIElement.self),
                                            kAXTitleAttribute as CFString, &title) == .success else { return "" }
        return title as? String ?? ""
    }
}

/// Transformaciones deterministas: solo tocan signos y mayúsculas, nunca palabras.
enum PunctuationStyle {
    static func apply(_ text: String, mode: WritingMode) -> String {
        switch mode {
        case .neutral: return text
        case .informal: return informal(text)
        case .formal: return formal(text)
        }
    }

    /// Sin signos de apertura y sin punto final (se respetan «?», «!» y los puntos suspensivos).
    static func informal(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "¿", with: "").replacingOccurrences(of: "¡", with: "")
        result = result.replacingOccurrences(of: "  ", with: " ")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasSuffix("."), !result.hasSuffix("..") { result.removeLast() }
        return result
    }

    /// Puntuación completa: abre ¿ y ¡ donde falten, mayúscula al inicio de frase y cierre con punto.
    static func formal(_ text: String) -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return source }
        var sentences: [String] = []
        var current = ""
        let characters = Array(source)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            if ".?!…".contains(character) {
                // Agrupa signos seguidos («?!», «...») y cierra la frase.
                while index + 1 < characters.count, ".?!…".contains(characters[index + 1]) {
                    index += 1
                    current.append(characters[index])
                }
                // Solo es fin de frase si detrás hay espacio o se acaba el texto («2.5», «heraldo.es» siguen juntos).
                if index + 1 >= characters.count || characters[index + 1].isWhitespace {
                    sentences.append(current)
                    current = ""
                }
            }
            index += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sentences.append(current) }

        var output = ""
        for (position, raw) in sentences.enumerated() {
            let leading = String(raw.prefix { $0.isWhitespace })
            var sentence = String(raw.dropFirst(leading.count))
            if sentence.hasSuffix("?"), !sentence.contains("¿") { sentence = "¿" + sentence }
            if sentence.hasSuffix("!"), !sentence.contains("¡") { sentence = "¡" + sentence }
            sentence = capitalizeFirstLetter(sentence)
            if position == sentences.count - 1, let last = sentence.last, !".?!…:;".contains(last) {
                sentence += "."
            }
            output += (position == 0 ? "" : (leading.isEmpty ? " " : leading)) + sentence
        }
        return output
    }

    private static func capitalizeFirstLetter(_ sentence: String) -> String {
        guard let index = sentence.firstIndex(where: { $0.isLetter }) else { return sentence }
        let prefix = sentence[..<index]
        // Solo si antes de la letra no hay más que signos de apertura o comillas.
        guard prefix.allSatisfy({ "¿¡\"'«“(".contains($0) }) else { return sentence }
        return String(prefix) + String(sentence[index]).uppercased() + String(sentence[sentence.index(after: index)...])
    }
}
