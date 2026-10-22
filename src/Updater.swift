import Foundation
import Darwin

/// Actualización automática desde GitHub, igual que «Uso de Claude»: cada 10 minutos
/// consulta el último commit de main y, si es nuevo, lanza instalar.sh, que compila
/// esa versión en este Mac, la firma con la identidad local y reinicia la app.
@MainActor final class AppUpdater: ObservableObject {
    static let repo = "jorgemoraz/dictado-mac"
    @Published var status = ""
    @Published private(set) var updating = false
    private var timer: Timer?

    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DictadoMac")
    }
    static var logPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DictadoMac-update.log").path
    }
    /// Solo las copias instaladas con instalar.sh llevan el commit y se actualizan solas.
    nonisolated static var installedCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "DMCommit") as? String
    }
    nonisolated static var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard let commit = installedCommit else { return "\(version) · compilación manual" }
        return "\(version) · \(commit.prefix(7))"
    }

    static func read(_ name: String) -> String? {
        (try? String(contentsOf: support.appendingPathComponent(name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// El instalador espera a que no haya un dictado en curso antes de reiniciar la app.
    static func markDictating(_ dictating: Bool) {
        let flag = support.appendingPathComponent("dictando")
        if dictating {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: flag.path, contents: Data("\(getpid())".utf8))
        } else {
            try? FileManager.default.removeItem(at: flag)
        }
    }

    func start() {
        guard Self.installedCommit != nil else {
            status = "Las actualizaciones automáticas se activan al instalar con instalar.sh."
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func check(manual: Bool = false) {
        guard !updating else { return }
        guard let installed = Self.installedCommit else {
            if manual { status = "Esta copia no se instaló con instalar.sh: no puede actualizarse sola." }
            return
        }
        if manual { status = "Buscando actualizaciones…" }
        Task { [weak self] in
            let latest = await Self.latest()
            guard let self else { return }
            guard let latest else {
                if manual { self.status = "No se ha podido consultar GitHub." }
                return
            }
            if latest == installed {
                if manual { self.status = "Tienes la última versión." }
                return
            }
            if latest == Self.read("failed") {
                self.status = "La versión \(latest.prefix(7)) no compiló; sigue la actual. Detalles en ~/Library/Logs/DictadoMac-update.log."
                return
            }
            guard Self.install(latest) else {
                self.status = "No se ha podido lanzar el instalador."
                return
            }
            self.updating = true
            self.status = "Instalando la versión \(latest.prefix(7)); Dictado Mac se reiniciará sola."
            // Si el instalador falla, se vuelve a intentar con el siguiente commit.
            try? await Task.sleep(for: .seconds(600))
            self.updating = false
        }
    }

    nonisolated static func latest() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/commits/main") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github.sha", forHTTPHeaderField: "Accept")
        request.setValue("DictadoMac", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let sha = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              sha.count == 40, sha.allSatisfy(\.isHexDigit) else { return nil }
        return sha
    }

    /// Lanza el instalador en su propia sesión para que sobreviva al reinicio de la app.
    nonisolated static func install(_ sha: String) -> Bool {
        let command = "curl -fsSL https://raw.githubusercontent.com/\(repo)/\(sha)/instalar.sh | /bin/bash -s -- --auto \(sha) >> '\(logPath)' 2>&1"
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(0x0400)) // POSIX_SPAWN_SETSID
        defer { posix_spawnattr_destroy(&attributes) }
        let arguments = ["/bin/bash", "-c", command]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        var environment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") }
        environment.append(nil)
        defer {
            argv.forEach { free($0) }
            environment.forEach { free($0) }
        }
        var pid: pid_t = 0
        return posix_spawn(&pid, "/bin/bash", nil, &attributes, argv, environment) == 0
    }
}
