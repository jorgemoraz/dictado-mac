import Foundation
nonisolated(unsafe) var failures = 0
func check<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    if got == want { print("OK  \(name)") } else { failures += 1; print("FALLO \(name)\n  obtenido: \(got)\n  esperado: \(want)") }
}

let rate = 16_000.0
/// Voz sintética: armónicos con F0 variable y algo de ruido determinista.
func voice(duration: Double, f0: (Double) -> Double) -> [Float] {
    var phase = 0.0
    var seed: UInt32 = 12345
    return (0..<Int(duration * rate)).map { n in
        let t = Double(n) / rate
        phase += 2 * Double.pi * f0(t) / rate
        var sample = 0.0
        for k in 1...6 { sample += sin(Double(k) * phase) / Double(k) }
        seed = seed &* 1_103_515_245 &+ 12_345
        let noise = (Double(seed >> 16) / 65_535 - 0.5) * 0.05
        return Float(0.25 * sample + noise)
    }
}
func glide(from a: Double, to b: Double, start: Double, end: Double) -> (Double) -> Double {
    { t in t < start ? a : a + (b - a) * min(1, (t - start) / (end - start)) }
}

let flat = voice(duration: 1.4) { _ in 140 }
let track = ProsodyAnalyzer.pitchTrack(samples: flat, sampleRate: rate, from: 0, to: 1.4)
let measured = ProsodyAnalyzer.median(track.map(\.f0))
check(abs(measured - 140) < 4, true, "mide 140 Hz (\(Int(measured)) Hz)")
check(ProsodyAnalyzer.intonation(samples: flat, sampleRate: rate, end: 1.4), .notRising, "tono plano: afirmación")

let rising = voice(duration: 1.4, f0: glide(from: 140, to: 200, start: 1.05, end: 1.4))
check(ProsodyAnalyzer.intonation(samples: rising, sampleRate: rate, end: 1.4), .rising, "sube al final: pregunta")

let falling = voice(duration: 1.4, f0: glide(from: 140, to: 100, start: 1.05, end: 1.4))
check(ProsodyAnalyzer.intonation(samples: falling, sampleRate: rate, end: 1.4), .notRising, "baja al final: afirmación")

let female = voice(duration: 1.4, f0: glide(from: 220, to: 320, start: 1.05, end: 1.4))
check(ProsodyAnalyzer.intonation(samples: female, sampleRate: rate, end: 1.4), .rising, "voz aguda que sube")

let silence = [Float](repeating: 0, count: Int(rate))
check(ProsodyAnalyzer.intonation(samples: silence, sampleRate: rate, end: 1), .unknown, "silencio: sin datos")

check(QuestionMarks.markLastSentence("Vienes mañana."), "¿Vienes mañana?", "pregunta simple")
check(QuestionMarks.markLastSentence("vienes mañana"), "¿vienes mañana?", "sin puntuación")
check(QuestionMarks.markLastSentence("Hola, Ana. Vienes mañana."), "Hola, Ana. ¿Vienes mañana?", "solo la última frase")
check(QuestionMarks.markLastSentence("¿Vienes mañana?"), "¿Vienes mañana?", "ya era pregunta")
check(QuestionMarks.markLastSentence("Vienes mañana?"), "¿Vienes mañana?", "añade la apertura")
check(QuestionMarks.markLastSentence("Qué bien!"), "Qué bien!", "respeta exclamación")
check(QuestionMarks.markLastSentence("Bueno..."), "Bueno...", "respeta suspensivos")
check(QuestionMarks.markLastSentence("Te llamo luego,"), "Te llamo luego,", "respeta coma")

print(failures == 0 ? "TODAS LAS PRUEBAS OK" : "PRUEBAS FALLIDAS: \(failures)")
exit(failures == 0 ? 0 : 1)
