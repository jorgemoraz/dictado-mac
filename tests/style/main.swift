import Foundation
var failures = 0
@MainActor func check(_ got: String, _ want: String, _ name: String) {
    if got == want { print("OK  \(name)") } else { failures += 1; print("FALLO \(name)\n  obtenido: \(got)\n  esperado: \(want)") }
}
check(PunctuationStyle.informal("¿Quedamos mañana a las 10?"), "Quedamos mañana a las 10?", "informal pregunta")
check(PunctuationStyle.informal("Vale, nos vemos luego."), "Vale, nos vemos luego", "informal punto final")
check(PunctuationStyle.informal("¡Qué bien! Nos vemos."), "Qué bien! Nos vemos", "informal exclamación")
check(PunctuationStyle.informal("Bueno..."), "Bueno...", "informal suspensivos")
check(PunctuationStyle.formal("quedamos mañana?"), "¿Quedamos mañana?", "formal abre interrogación")
check(PunctuationStyle.formal("Hola Ana. te envío el informe"), "Hola Ana. Te envío el informe.", "formal mayúscula y punto")
check(PunctuationStyle.formal("Gracias. qué bien!"), "Gracias. ¡Qué bien!", "formal exclamación")
check(PunctuationStyle.formal("¿Puedes revisarlo? Gracias."), "¿Puedes revisarlo? Gracias.", "formal ya correcto")
check(PunctuationStyle.formal("El precio es 2.5 euros"), "El precio es 2.5 euros.", "formal decimal")
print(failures == 0 ? "TODAS LAS PRUEBAS OK" : "PRUEBAS FALLIDAS: \(failures)")
exit(failures == 0 ? 0 : 1)
