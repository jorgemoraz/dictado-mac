import SwiftUI
import AppKit
import AVFoundation
@preconcurrency import ApplicationServices
import Carbon
import Darwin

enum DictationPhase: Equatable {
    case preparing, ready, recording, finishing, failed
    var label: String {
        switch self {
        case .preparing: return "Preparando motor nativo…"
        case .ready: return "Listo · mantén el atajo para hablar"
        case .recording: return "Dictando · suelta el atajo para terminar"
        case .finishing: return "Terminando la última palabra…"
        case .failed: return "El dictado necesita atención"
        }
    }
}

@MainActor final class IndicatorModel: ObservableObject {
    @Published var title = "Dictando"
    @Published var partial = ""
    @Published var level: Float = 0
}

private struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(model.title == "Dictando" ? Color.red : .orange).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).font(.system(size: 14, weight: .semibold))
                if !model.partial.isEmpty { Text(model.partial).font(.system(size: 12)).lineLimit(2) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                ForEach(0..<5) { i in
                    Capsule().fill(.white.opacity(0.8))
                        .frame(width: 3, height: 5 + CGFloat(model.level) * CGFloat([14, 26, 35, 26, 14][i]))
                }
            }.frame(width: 30, height: 40)
        }
        .foregroundStyle(.white).padding(16).frame(width: 370, alignment: .leading)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 20))
        .padding(8)
        .accessibilityLabel(model.title)
    }
}

private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class DictationIndicator {
    let model = IndicatorModel()
    private var panel: NSPanel?
    func show(_ title: String) {
        model.title = title
        if panel == nil {
            let panel = IndicatorPanel(contentRect: .init(x: 0, y: 0, width: 386, height: 108),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.contentView = NSHostingView(rootView: IndicatorView(model: model))
            self.panel = panel
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel?.setFrameOrigin(.init(x: screen.visibleFrame.midX - 193, y: screen.visibleFrame.minY + 22))
        }
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil); model.level = 0 }
}

@MainActor final class DictationController: ObservableObject {
    @Published var phase: DictationPhase = .preparing {
        didSet { AppUpdater.markDictating(phase == .recording || phase == .finishing) }
    }
    let updater = AppUpdater()
    @Published var text = UserDefaults.standard.string(forKey: "ultimoTexto") ?? "" {
        didSet { UserDefaults.standard.set(text, forKey: "ultimoTexto") }
    }
    @Published var original = UserDefaults.standard.string(forKey: "textoOriginal") ?? ""
    @Published var partial = ""
    @Published var message = ""
    @Published var insertionStatus = "Haz clic en un campo de texto y mantén el atajo."
    @Published var shortcutStatus = "Comprobando atajos…"
    @Published var triggers: [HotkeyTrigger] = DictationController.loadTriggers() {
        didSet {
            if let data = try? JSONEncoder().encode(triggers) { UserDefaults.standard.set(data, forKey: "atajos") }
            shortcut?.setTriggers(triggers)
        }
    }
    @Published var recordingShortcut = false
    @Published var shortcutMessage = ""
    @Published var accessibility = AXIsProcessTrusted()
    @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var vocabulary = UserDefaults.standard.stringArray(forKey: "vocabulario") ?? []
    @Published var corrections = UserDefaults.standard.dictionary(forKey: "correcciones") as? [String: String] ?? [:]
    @Published var polish = UserDefaults.standard.object(forKey: "correccionContextual") as? Bool ?? true {
        didSet { UserDefaults.standard.set(polish, forKey: "correccionContextual") }
    }
    @Published var polishStatus = "La puntuación de macOS se inserta directamente."
    @Published var questionsByIntonation = UserDefaults.standard.object(forKey: "preguntasPorEntonacion") as? Bool ?? true {
        didSet { UserDefaults.standard.set(questionsByIntonation, forKey: "preguntasPorEntonacion") }
    }
    private var engine: NativeDictationEngine?
    private var preparing: Task<Void, Never>?
    private var nextPreparation: Task<NativeDictationEngine, Error>?
    private var finishing: Task<Void, Never>?
    private var polishing: Task<Void, Never>?
    private var generation = UUID()
    private var pressed = false
    private var starting = false
    private var stopRequested = false
    private var backgroundStatus: Timer?
    private let indicator = DictationIndicator()
    private var shortcut: HotkeyShortcut!
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    var busy: Bool { phase == .recording || phase == .finishing }
    init() {
        shortcut = HotkeyShortcut(triggers: triggers,
            onDown: { [weak self] in self?.fnDown() },
            onUp: { [weak self] in self?.fnUp() },
            onAbort: { [weak self] in self?.holdAborted() },
            onStatus: { [weak self] in self?.shortcutStatus = $0 },
            onRecorded: { [weak self] in self?.recorded($0) })
        shortcut.start()
        installAlternateShortcut()
        backgroundStatus = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        prepare()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recoverAfterWake() }
            }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.audioConfigurationChanged() }
            }
    }

    func refreshPermissions() {
        let hadAccess = accessibility
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        shortcut.refresh()
        if accessibility && !hadAccess { message = "Accesibilidad activada. Los atajos ya funcionan en otras apps." }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
    }
    func requestMicrophone() {
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        } else { openSettings("Privacy_Microphone") }
    }
    private func openSettings(_ page: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(page)") { NSWorkspace.shared.open(url) }
    }
    func prepare() {
        guard preparing == nil, nextPreparation == nil, finishing == nil, !busy else { return }
        phase = .preparing
        let terms = vocabulary
        preparing = Task { [weak self] in
            do {
                let ready = try await NativeDictationEngine.prepare(vocabulary: terms)
                guard let self, !Task.isCancelled else { ready.cancel(); return }
                self.engine = ready
                self.phase = .ready
                self.preparing = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.message = error.localizedDescription
                self.phase = .failed
                self.preparing = nil
            }
        }
    }
    private func fnDown() {
        guard !pressed else { return }
        pressed = true
        start()
    }
    private func fnUp() {
        pressed = false
        if phase == .recording { stop() }
    }
    /// Se pulsó otra tecla nada más empezar: era otro atajo, no un dictado.
    private func holdAborted() {
        pressed = false
        if phase == .recording { cancel() }
    }

    nonisolated static func loadTriggers() -> [HotkeyTrigger] {
        guard let data = UserDefaults.standard.data(forKey: "atajos"),
              let saved = try? JSONDecoder().decode([HotkeyTrigger].self, from: data), !saved.isEmpty else {
            return HotkeyTrigger.defaults
        }
        return saved
    }
    func label(_ trigger: HotkeyTrigger) -> String { trigger.label(keyName: { KeyNames.name($0) }) }
    var shortcutSummary: String { triggers.map { label($0) }.joined(separator: "  o  ") }
    func startRecordingShortcut() {
        guard accessibility else {
            shortcutMessage = "Primero permite Accesibilidad: hace falta para leer el teclado."
            return
        }
        shortcutMessage = ""
        recordingShortcut = true
        shortcut.startRecording()
    }
    func cancelRecordingShortcut() {
        recordingShortcut = false
        shortcut.cancelRecording()
    }
    private func recorded(_ trigger: HotkeyTrigger?) {
        recordingShortcut = false
        guard let trigger else { shortcutMessage = "Grabación cancelada."; return }
        if let problem = trigger.problem { shortcutMessage = problem; return }
        guard !triggers.contains(trigger) else { shortcutMessage = "Ese atajo ya está en la lista."; return }
        triggers.append(trigger)
        shortcutMessage = "Añadido: \(label(trigger))."
    }
    func removeTrigger(_ trigger: HotkeyTrigger) {
        guard triggers.count > 1 else { return }
        triggers.removeAll { $0 == trigger }
    }
    func restoreDefaultTriggers() {
        triggers = HotkeyTrigger.defaults
        shortcutMessage = "Restaurados Fn y ⌃ + ⌥ izquierdos."
    }
    func toggle() {
        if phase == .recording { stop() } else if phase == .ready { start() }
    }
    func start() {
        guard phase == .ready, let engine else {
            if phase == .preparing { message = "Espera a que aparezca «Listo» antes de hablar." }
            return
        }
        refreshPermissions()
        guard microphone == .authorized else {
            message = "Permite el micrófono para comenzar."
            requestMicrophone()
            return
        }
        polishing?.cancel(); polishing = nil
        message = ""
        generation = UUID()
        let token = generation
        stopRequested = false
        partial = ""
        indicator.model.partial = ""
        if let targetName = TextInserter.frontmostTargetName() {
            insertionStatus = accessibility
                ? "Destino: \(targetName). Se pegará al soltar el atajo."
                : "Falta Accesibilidad: el texto quedará en Dictado Mac."
        } else {
            insertionStatus = "Dictado dentro de la app. El resultado también se guarda aquí."
        }
        engine.detectQuestions = questionsByIntonation
        phase = .recording
        starting = true
        indicator.show("Dictando")
        Task { [weak self] in
            do {
                try await engine.start(onText: { [weak self] value in
                    guard let self, self.generation == token,
                          self.phase == .recording || self.phase == .finishing else { return }
                    let corrected = ExplicitCorrections.apply(value, corrections: self.corrections)
                    self.partial = corrected
                    self.indicator.model.partial = String(corrected.suffix(150))
                }, onLevel: { [weak self] level in
                    guard let self, self.generation == token else { return }
                    self.indicator.model.level = level
                }, onError: { [weak self] error in
                    guard let self, self.generation == token else { return }
                    self.message = error
                    if self.phase == .recording { self.stop() }
                })
                guard let self, self.generation == token else { engine.cancel(); return }
                self.starting = false
                if self.stopRequested || (self.pressed == false && self.phase == .finishing) { self.complete(engine, token: token) }
            } catch {
                guard let self, self.generation == token else { return }
                engine.cancel()
                self.starting = false
                self.message = error.localizedDescription
                self.indicator.hide()
                self.engine = nil
                self.phase = .ready
                self.prepare()
            }
        }
    }
    func stop() {
        guard phase == .recording else { return }
        stopRequested = true
        phase = .finishing
        indicator.show("Terminando…")
        if let engine, !starting { complete(engine, token: generation) }
    }
    private func complete(_ active: NativeDictationEngine, token: UUID) {
        guard finishing == nil else { return }
        finishing = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == token else { return }
            let result = await active.finish()
            guard !Task.isCancelled, self.generation == token else { return }
            if active.questionsDetected > 0 {
                self.polishStatus = active.questionsDetected == 1
                    ? "Pregunta detectada por la entonación."
                    : "\(active.questionsDetected) preguntas detectadas por la entonación."
            }
            let terms = self.vocabulary
            let warming = Task { try await NativeDictationEngine.prepare(vocabulary: terms) }
            self.nextPreparation = warming
            let raw = result.trimmingCharacters(in: .whitespacesAndNewlines)
            var final = ExplicitCorrections.apply(raw, corrections: self.corrections)
            self.original = raw
            UserDefaults.standard.set(raw, forKey: "textoOriginal")
            self.partial = ""
            // Como Wispr Flow: el pulido se hace ANTES de pegar, con un plazo corto.
            // Nunca se reescribe el campo después de pegar.
            if self.polish, !final.isEmpty {
                self.indicator.show("Puliendo…")
                self.polishStatus = "Revisando puntuación…"
                let revised = await ContextRevision.revise(final, vocabulary: terms, timeout: .milliseconds(1200))
                guard !Task.isCancelled, self.generation == token else { return }
                final = revised.text
                self.polishStatus = revised.status
            }
            if !final.isEmpty { self.text = final }
            self.indicator.hide()
            if !final.isEmpty {
                let outcome = await TextInserter.insert(final)
                guard !Task.isCancelled, self.generation == token else { return }
                self.insertionStatus = outcome.message
                if !outcome.inserted { self.message = outcome.message }
            } else {
                self.message = active.lastError ?? "No se ha reconocido voz. Comprueba el micrófono y vuelve a mantener el atajo."
            }
            self.engine = nil
            self.phase = .preparing
            do {
                let ready = try await warming.value
                guard !Task.isCancelled, self.generation == token else { ready.cancel(); return }
                self.engine = ready
                self.phase = .ready
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.phase = .failed
                self.message = error.localizedDescription
            }
            self.nextPreparation = nil
            self.finishing = nil
        }
    }
    func cancel() {
        generation = UUID()
        pressed = false
        starting = false
        stopRequested = true
        preparing?.cancel(); preparing = nil
        nextPreparation?.cancel(); nextPreparation = nil
        finishing?.cancel(); finishing = nil
        polishing?.cancel(); polishing = nil
        engine?.cancel(); engine = nil
        indicator.hide()
        phase = .ready
        prepare()
    }
    private func recoverAfterWake() {
        shortcut.refresh()
        if phase == .recording { message = "El Mac ha despertado. Vuelve a mantener el atajo para continuar."; stop(); return }
        if !busy { engine?.cancel(); engine = nil; preparing?.cancel(); preparing = nil; prepare() }
    }
    private func audioConfigurationChanged() {
        if phase == .recording {
            message = "El micrófono ha cambiado. Se conserva lo reconocido; vuelve a mantener el atajo."
            stop()
        } else if phase == .ready { recoverAfterWake() }
    }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func saveVocabulary(_ term: String) {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !vocabulary.contains(clean) else { return }
        vocabulary.append(clean); vocabulary.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        UserDefaults.standard.set(vocabulary, forKey: "vocabulario")
        if !busy { engine?.cancel(); engine = nil; preparing?.cancel(); preparing = nil; prepare() }
    }
    func saveCorrection(_ from: String, _ to: String) {
        let source = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !destination.isEmpty else { return }
        corrections[source] = destination
        UserDefaults.standard.set(corrections, forKey: "correcciones")
    }
    func importVocabulary() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = "TXT, CSV o TSV con un término por línea o pares origen/destino."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let (rows, invalid) = DictionaryImportParser.parse(content)
            for row in rows {
                switch row {
                case .term(let term): if !vocabulary.contains(term) { vocabulary.append(term) }
                case .correction(let source, let target): corrections[source] = target
                }
            }
            UserDefaults.standard.set(vocabulary, forKey: "vocabulario")
            UserDefaults.standard.set(corrections, forKey: "correcciones")
            message = "Importadas \(rows.count) entradas.\(invalid > 0 ? " Filas no válidas: \(invalid)." : "")"
            if !busy { engine?.cancel(); engine = nil; preparing?.cancel(); preparing = nil; prepare() }
        } catch { message = "No se pudo leer el archivo: \(error.localizedDescription)" }
    }
    func shutdown() {
        backgroundStatus?.invalidate()
        shortcut.stop()
        engine?.cancel()
        indicator.hide()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }
    private func installAlternateShortcut() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<DictationController>.fromOpaque(data).takeUnretainedValue()
            Task { @MainActor in controller.toggle() }
            return noErr
        }, 1, &eventType, pointer, &hotKeyHandler)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: OSType(0x44494354), id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }
}

struct MainView: View {
    @ObservedObject var model: DictationController
    @ObservedObject var updater: AppUpdater
    @State private var term = ""
    @State private var from = ""
    @State private var to = ""
    @State private var showDictionary = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("Dictado Mac").font(.title2.bold())
                    Text(model.phase.label).font(.subheadline).accessibilityIdentifier("dictation-status")
                }
                Spacer()
                Button(model.phase == .recording ? "Terminar" : "Dictar aquí") { model.toggle() }
                    .disabled(model.phase != .ready && model.phase != .recording)
                if model.busy { Button("Cancelar") { model.cancel() } }
            }
            GroupBox("Atajos: mantén uno pulsado para hablar y suéltalo para terminar") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.triggers) { trigger in
                        HStack {
                            Text(model.label(trigger)).font(.body.monospaced())
                            Spacer()
                            Button("Quitar") { model.removeTrigger(trigger) }
                                .disabled(model.triggers.count <= 1 || model.recordingShortcut)
                        }
                    }
                    HStack {
                        if model.recordingShortcut {
                            Text("Pulsa la combinación y suéltala… (Esc cancela)").foregroundStyle(.blue)
                            Button("Cancelar") { model.cancelRecordingShortcut() }
                        } else {
                            Button("Añadir atajo…") { model.startRecordingShortcut() }
                            Button("Restaurar Fn y ⌃ + ⌥ izq.") { model.restoreDefaultTriggers() }
                        }
                        Spacer()
                    }
                    if !model.shortcutMessage.isEmpty { Text(model.shortcutMessage).font(.caption).foregroundStyle(.orange) }
                    Text("También ⌃⌥Espacio para empezar y terminar sin mantener. Las combinaciones de solo modificadoras se activan tras 0,15 s para no chocar con otros atajos.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.shortcutStatus).font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            if !model.accessibility {
                HStack {
                    Text("Accesibilidad permite detectar los atajos e insertar en otras apps.")
                    Spacer()
                    Button("Permitir Accesibilidad") { model.requestAccessibility() }
                }.padding(10).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.microphone != .authorized {
                HStack { Text("Falta permiso de micrófono."); Spacer(); Button("Permitir micrófono") { model.requestMicrophone() } }
            }
            if !model.message.isEmpty { Text(model.message).foregroundStyle(.orange).textSelection(.enabled) }
            Text(model.insertionStatus).font(.callout).foregroundStyle(.secondary)
            Toggle("Revisar puntuación y ortografía con IA local antes de pegar (máx. 1,2 s)", isOn: $model.polish).disabled(model.busy)
            Toggle("Detectar preguntas por la entonación (tono que sube al final → ¿…?)", isOn: $model.questionsByIntonation).disabled(model.busy)
            Text(model.polishStatus).font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text(model.phase == .recording ? "Transcripción en directo" : "Último dictado").font(.headline)
                Spacer()
                Button("Copiar") { model.copy() }.disabled(model.text.isEmpty || model.busy)
                if model.phase == .failed { Button("Reintentar motor") { model.prepare() } }
            }
            if model.busy {
                ScrollView { Text(model.partial.isEmpty ? "Escuchando…" : model.partial).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(minHeight: 120)
            } else {
                TextEditor(text: $model.text).font(.body).frame(minHeight: 120).accessibilityLabel("Último dictado")
            }
            DisclosureGroup("Diccionario personal (\(model.vocabulary.count)) y correcciones (\(model.corrections.count))", isExpanded: $showDictionary) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Nombre o término", text: $term)
                        Button("Añadir") { model.saveVocabulary(term); term = "" }.disabled(model.busy)
                        Button("Importar TXT/CSV") { model.importVocabulary() }.disabled(model.busy)
                    }
                    Text(model.vocabulary.joined(separator: " · ")).font(.caption).textSelection(.enabled).lineLimit(4)
                    HStack {
                        TextField("Reconoció", text: $from)
                        TextField("Debe decir", text: $to)
                        Button("Guardar") { model.saveCorrection(from, to); from = ""; to = "" }.disabled(model.busy)
                    }
                    Text("Las sustituciones son explícitas. El reconocimiento y la revisión se realizan en el Mac.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
            Text("Motor nativo de macOS · español · sin Whisper ni servicios de pago").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Versión \(AppUpdater.versionLabel)").font(.caption).foregroundStyle(.secondary)
                Button("Buscar actualizaciones") { updater.check(manual: true) }
                    .controlSize(.small).disabled(updater.updating)
                if !updater.status.isEmpty { Text(updater.status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }.padding(22).frame(minWidth: 640, minHeight: 760)
    }
}

private final class InstanceLock {
    private let descriptor: Int32
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DictadoMac")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { exit(1) }
        // Acquire before installing any event tap or preparing the speech engine.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); exit(0) }
    }
    deinit { close(descriptor) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = InstanceLock()
    let model = DictationController()
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = NSMenu()
        let applicationItem = NSMenuItem()
        menuBar.addItem(applicationItem)
        let applicationMenu = NSMenu(title: "Dictado Mac")
        applicationMenu.addItem(withTitle: "Acerca de Dictado Mac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Ocultar Dictado Mac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(withTitle: "Salir de Dictado Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        let editItem = NSMenuItem()
        menuBar.addItem(editItem)
        let editMenu = NSMenu(title: "Edición")
        for (title, selector, key) in [("Deshacer", "undo:", "z"), ("Cortar", "cut:", "x"), ("Copiar", "copy:", "c"),
                                      ("Pegar", "paste:", "v"), ("Seleccionar todo", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        NSApp.mainMenu = menuBar
        model.updater.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Dictado Mac")
        let menu = NSMenu()
        menu.addItem(withTitle: "Abrir Dictado Mac", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
        if ProcessInfo.processInfo.arguments.contains("--autostart") {
            NSApp.setActivationPolicy(.accessory)
        } else { showWindow() }
    }
    @objc func showWindow() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Dictado Mac"
            window.identifier = NSUserInterfaceItemIdentifier("DictadoMac.main")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView(model: model, updater: model.updater))
            window.center()
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        AppUpdater.markDictating(false)
        model.shutdown()
    }
}

@main enum DictadoMacApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(CommandLine.arguments.contains("--autostart") ? .accessory : .regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }
}
