import Foundation
nonisolated(unsafe) var failures = 0
func check<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    if got == want { print("OK  \(name)") } else { failures += 1; print("FALLO \(name)\n  obtenido: \(got)\n  esperado: \(want)") }
}
let ctrlOpt: ModifierSet = [.leftControl, .leftOption]

// Fn: inmediato, como en la 5.0.
var m = HotkeyMatcher(triggers: HotkeyTrigger.defaults)
check(m.modifiersChanged(.fn, at: 0), [.down], "Fn pulsa")
check(m.modifiersChanged([], at: 2), [.up], "Fn suelta")

// ⌃⌥ izquierdos: esperan 0,15 s.
m = HotkeyMatcher(triggers: HotkeyTrigger.defaults)
check(m.modifiersChanged(.leftControl, at: 0), [], "⌃ sola no hace nada")
check(m.modifiersChanged(ctrlOpt, at: 0.02), [], "⌃⌥ pendiente")
check(m.tick(at: 0.10), [], "⌃⌥ aún no")
check(m.tick(at: 0.18), [.down], "⌃⌥ empieza")
check(m.modifiersChanged(.leftOption, at: 3), [.up], "soltar ⌃ termina")
check(m.modifiersChanged(ctrlOpt, at: 3.1), [], "sin soltar todo no rearma")
check(m.tick(at: 3.5), [], "bloqueado hasta soltar")
check(m.modifiersChanged([], at: 4), [], "suelta todo")

// Lado derecho no cuenta.
m = HotkeyMatcher(triggers: HotkeyTrigger.defaults)
_ = m.modifiersChanged([.rightControl, .rightOption], at: 0)
check(m.tick(at: 1), [], "⌃⌥ derechos no activan")

// ⌃⌥Espacio rápido no dicta.
m = HotkeyMatcher(triggers: HotkeyTrigger.defaults)
_ = m.modifiersChanged(ctrlOpt, at: 0)
check(m.keyDown(49, isRepeat: false, at: 0.05).0, [], "⌃⌥Espacio rápido")
check(m.keyDown(49, isRepeat: false, at: 0.05).1, false, "Espacio no se consume")
check(m.tick(at: 1), [], "tras otro atajo no empieza")

// Otra tecla justo después de empezar: se descarta; más tarde: termina.
m = HotkeyMatcher(triggers: HotkeyTrigger.defaults)
_ = m.modifiersChanged(.fn, at: 0)
check(m.keyDown(126, isRepeat: false, at: 0.2).0, [.abort], "Fn+flecha descarta")
m = HotkeyMatcher(triggers: HotkeyTrigger.defaults)
_ = m.modifiersChanged(.fn, at: 0)
check(m.keyDown(126, isRepeat: false, at: 2).0, [.up], "tecla tardía termina")
m = HotkeyMatcher(triggers: HotkeyTrigger.defaults)
_ = m.modifiersChanged(ctrlOpt, at: 0); _ = m.tick(at: 0.2)
check(m.modifiersChanged([.leftControl, .leftOption, .leftCommand], at: 0.3), [.abort], "añadir ⌘ al empezar descarta")

// Atajo con tecla normal: se consume para que no se escriba.
let custom = HotkeyTrigger(modifiers: [.rightOption], key: 2)
m = HotkeyMatcher(triggers: [custom])
_ = m.modifiersChanged(.rightOption, at: 0)
let down = m.keyDown(2, isRepeat: false, at: 0.01)
check(down.0, [.down], "⌥ dcha.+D empieza")
check(down.1, true, "D consumida")
check(m.keyDown(2, isRepeat: true, at: 0.5).1, true, "repetición consumida")
check(m.modifiersChanged([], at: 1).first, .up, "soltar ⌥ termina")
check(m.keyDown(2, isRepeat: true, at: 1.1).1, true, "repetición tras terminar consumida")
check(m.keyUp(2).1, true, "keyUp consumido")
check(m.keyDown(2, isRepeat: false, at: 2).0, [], "D sola no dicta")

// Tecla F sola.
let f13 = HotkeyTrigger(modifiers: [], key: 105)
m = HotkeyMatcher(triggers: [f13])
check(m.keyDown(105, isRepeat: false, at: 0).0, [.down], "F13 empieza")
check(m.keyUp(105).0, [.up], "F13 termina")

// Grabación.
var r = HotkeyRecorder()
_ = r.modifiersChanged(.leftControl)
_ = r.modifiersChanged(ctrlOpt)
_ = r.modifiersChanged(.leftOption)
check(r.modifiersChanged([]), HotkeyTrigger.leftControlOption, "graba ⌃⌥")
check(r.keyDown(2, held: .rightOption), custom, "graba ⌥ dcha.+D")

// Validación y lectura de flags.
check(HotkeyTrigger(modifiers: [], key: 2).problem != nil, true, "letra sola rechazada")
check(f13.problem == nil, true, "F13 sola válida")
check(ModifierSet.from(eventFlags: 0x0004_0000 | 0x0008_0000 | 0x01 | 0x20, fnHeld: false), ctrlOpt, "flags ⌃⌥ izq.")
check(ModifierSet.from(eventFlags: 0x0008_0000 | 0x40, fnHeld: false), [.rightOption], "flags ⌥ dcha.")
check(ModifierSet.from(eventFlags: 0x0004_0000, fnHeld: true), [.fn, .leftControl], "flags genéricos")
let encoded = try! JSONEncoder().encode(HotkeyTrigger.defaults)
check(try! JSONDecoder().decode([HotkeyTrigger].self, from: encoded), HotkeyTrigger.defaults, "guardar y leer")

print(failures == 0 ? "TODAS LAS PRUEBAS OK" : "PRUEBAS FALLIDAS: \(failures)")
exit(failures == 0 ? 0 : 1)
