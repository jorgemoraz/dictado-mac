import Foundation

/// Copia compartible del diccionario personal: términos, sustituciones y lo borrado.
struct SharedDictionary: Codable, Equatable, Sendable {
    var terminos: [String] = []
    var correcciones: [String: String] = [:]
    /// Términos u orígenes de sustitución borrados: así no reaparecen desde otro Mac.
    var eliminados: [String] = []
    var actualizado: Date = .distantPast

    /// Mismo contenido sin importar el orden: Windows ordena distinto y no debe provocar reescrituras.
    func sameContent(as other: SharedDictionary) -> Bool {
        Set(terminos) == Set(other.terminos) && correcciones == other.correcciones && Set(eliminados) == Set(other.eliminados)
    }

    /// Une dos copias. Lo borrado no reaparece desde otro Mac (salvo que se vuelva a
    /// añadir después); en sustituciones con el mismo origen gana la copia más reciente.
    static func merge(_ a: SharedDictionary, _ b: SharedDictionary) -> SharedDictionary {
        let (older, newer) = a.actualizado <= b.actualizado ? (a, b) : (b, a)
        // Un borrado antiguo no anula lo que la copia más reciente ha vuelto a añadir.
        let restored = Set(newer.terminos).union(newer.correcciones.keys)
        let removed = Set(newer.eliminados).union(Set(older.eliminados).subtracting(restored))
        var seen = Set<String>()
        var terms: [String] = []
        // Ante la misma palabra con distinta grafía, manda la copia más reciente.
        for term in newer.terminos + older.terminos {
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = clean.lowercased()
            guard !clean.isEmpty, !removed.contains(clean), !seen.contains(key) else { continue }
            seen.insert(key)
            terms.append(clean)
        }
        terms.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var corrections = older.correcciones.merging(newer.correcciones) { _, latest in latest }
        for key in removed { corrections.removeValue(forKey: key) }
        return SharedDictionary(terminos: terms, correcciones: corrections,
                                eliminados: removed.sorted(), actualizado: max(a.actualizado, b.actualizado))
    }
}

/// Sincroniza el diccionario entre todos los Macs mediante un archivo en iCloud Drive
/// («Dictado Mac/diccionario.json»). Privado, sin claves y sin pasar por GitHub.
@MainActor final class DictionarySync {
    nonisolated static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    nonisolated static var folder: URL { iCloudDrive.appendingPathComponent("Dictado Mac", isDirectory: true) }
    nonisolated static var file: URL { folder.appendingPathComponent("diccionario.json") }

    private let current: @MainActor () -> SharedDictionary
    private let apply: @MainActor (SharedDictionary) -> Void
    private let report: @MainActor (String) -> Void
    private var timer: Timer?

    init(current: @escaping @MainActor () -> SharedDictionary,
         apply: @escaping @MainActor (SharedDictionary) -> Void,
         report: @escaping @MainActor (String) -> Void) {
        self.current = current
        self.apply = apply
        self.report = report
    }

    func start() {
        sync()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    func sync() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: Self.iCloudDrive.path) else {
            report("iCloud Drive no está activo en este Mac: el diccionario solo se guarda aquí.")
            return
        }
        do {
            try manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        } catch {
            report("Sin acceso a iCloud Drive: permite a Dictado Mac usarlo para compartir el diccionario.")
            return
        }
        try? manager.startDownloadingUbiquitousItem(at: Self.file)
        let local = current()
        var remote = SharedDictionary()
        if manager.fileExists(atPath: Self.file.path) {
            guard let data = try? Data(contentsOf: Self.file) else {
                report("El diccionario de iCloud aún se está descargando.")
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let decoded = try? decoder.decode(SharedDictionary.self, from: data) else {
                report("No se ha podido leer el diccionario de iCloud; se conserva el de este Mac.")
                return
            }
            remote = decoded
        }
        var merged = SharedDictionary.merge(local, remote)
        if !merged.sameContent(as: local) { apply(merged) }
        if !merged.sameContent(as: remote) || !manager.fileExists(atPath: Self.file.path) {
            merged.actualizado = max(merged.actualizado, Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try encoder.encode(merged).write(to: Self.file, options: .atomic)
            } catch {
                report("No se ha podido guardar el diccionario en iCloud Drive.")
                return
            }
        }
        report("Sincronizado con iCloud Drive en todos tus Macs (\(merged.terminos.count) términos, \(merged.correcciones.count) sustituciones).")
    }
}
