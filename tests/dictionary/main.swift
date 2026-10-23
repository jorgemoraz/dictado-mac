import Foundation
nonisolated(unsafe) var failures = 0
func check<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    if got == want { print("OK  \(name)") } else { failures += 1; print("FALLO \(name)\n  obtenido: \(got)\n  esperado: \(want)") }
}
let older = Date(timeIntervalSince1970: 1_000)
let newer = Date(timeIntervalSince1970: 2_000)

let mini = SharedDictionary(terminos: ["Zaragoza", "Heraldo", "Xalok"], correcciones: ["eraldo": "Heraldo"], actualizado: newer)
let macbook = SharedDictionary(terminos: ["heraldo", "Cosas con Botones"], correcciones: ["eraldo": "HERALDO", "trovadora": "Trobadora"], actualizado: older)
let merged = SharedDictionary.merge(mini, macbook)
check(merged.terminos, ["Cosas con Botones", "Heraldo", "Xalok", "Zaragoza"], "une términos sin duplicar mayúsculas")
check(merged.correcciones, ["eraldo": "Heraldo", "trovadora": "Trobadora"], "une sustituciones; gana la más reciente")
check(merged.actualizado, newer, "conserva la fecha más reciente")
check(SharedDictionary.merge(macbook, mini), merged, "el orden no importa")

let latest = Date(timeIntervalSince1970: 3_000)
let deleted = SharedDictionary(terminos: ["Heraldo"], correcciones: [:], eliminados: ["Xalok", "eraldo"], actualizado: latest)
let afterDelete = SharedDictionary.merge(deleted, mini)
check(afterDelete.terminos, ["Heraldo", "Zaragoza"], "lo borrado en un Mac no reaparece")
check(afterDelete.correcciones, [:], "sustitución borrada")
check(SharedDictionary.merge(afterDelete, afterDelete).sameContent(as: afterDelete), true, "fusionar dos veces no cambia nada")
check(SharedDictionary.merge(SharedDictionary(), mini).sameContent(as: SharedDictionary.merge(mini, SharedDictionary())), true, "copia vacía")

let readded = SharedDictionary(terminos: ["Heraldo", "Xalok"], correcciones: [:], eliminados: [], actualizado: Date(timeIntervalSince1970: 4_000))
let afterReadd = SharedDictionary.merge(afterDelete, readded)
check(afterReadd.terminos, ["Heraldo", "Xalok", "Zaragoza"], "volver a añadir algo borrado")
check(afterReadd.eliminados, ["eraldo"], "el borrado anulado desaparece")

let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let roundTrip = try! decoder.decode(SharedDictionary.self, from: try! encoder.encode(merged))
check(roundTrip, merged, "guardar y leer el JSON")

print(failures == 0 ? "TODAS LAS PRUEBAS OK" : "PRUEBAS FALLIDAS: \(failures)")
exit(failures == 0 ? 0 : 1)
