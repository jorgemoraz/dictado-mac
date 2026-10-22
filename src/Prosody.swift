import Foundation

/// Entonación del final de una frase.
enum Intonation: Equatable, Sendable { case rising, notRising, unknown }

/// Detección de preguntas por la entonación: en español, «¿Vienes mañana?» y
/// «Vienes mañana.» solo se distinguen por la subida de tono final.
/// Todo es local y determinista; sin modelos ni red.
enum ProsodyAnalyzer {
    /// Subida mínima del final respecto a lo anterior, en semitonos.
    static let riseThreshold: Double = 2.5

    static func intonation(samples: [Float], sampleRate: Double, end: Double, lookBack: Double = 1.6) -> Intonation {
        classify(pitchTrack(samples: samples, sampleRate: sampleRate,
                            from: max(0, end - lookBack), to: end + 0.15))
    }

    static func classify(_ track: [(time: Double, f0: Double)]) -> Intonation {
        guard track.count >= 12, let lastTime = track.last?.time else { return .unknown }
        let reference = median(track.map(\.f0))
        guard reference > 0 else { return .unknown }
        func semitones(_ f0: Double) -> Double { 12 * log2(f0 / reference) }
        // Pico final (últimos 150 ms con voz) frente al tramo previo (de 0,7 a 0,25 s antes).
        let tail = track.filter { $0.time >= lastTime - 0.15 }.map { semitones($0.f0) }
        let before = track.filter { $0.time < lastTime - 0.25 && $0.time >= lastTime - 0.7 }.map { semitones($0.f0) }
        guard tail.count >= 4 else { return .unknown }
        let endLevel = median(tail)
        let startLevel = before.count >= 4 ? median(before) : 0
        return endLevel - startLevel >= riseThreshold && endLevel >= 1 ? .rising : .notRising
    }

    /// Curva de tono (F0) por autocorrelación normalizada: ventanas de 40 ms cada 10 ms.
    static func pitchTrack(samples: [Float], sampleRate: Double, from: Double, to: Double) -> [(time: Double, f0: Double)] {
        let window = Int(0.04 * sampleRate)
        let hop = max(1, Int(0.01 * sampleRate))
        let minLag = max(2, Int(sampleRate / 400))
        let maxLag = Int(sampleRate / 70)
        guard window > maxLag + 16, samples.count > window else { return [] }
        let first = max(0, Int(from * sampleRate))
        let last = min(samples.count - window, Int(to * sampleRate))
        guard last > first else { return [] }

        var frames: [(time: Double, rms: Float, f0: Double?)] = []
        var x = [Float](repeating: 0, count: window)
        var start = first
        while start <= last {
            var mean: Float = 0
            for i in 0..<window { mean += samples[start + i] }
            mean /= Float(window)
            var energy: Float = 0
            for i in 0..<window {
                let value = samples[start + i] - mean
                x[i] = value
                energy += value * value
            }
            let rms = (energy / Float(window)).squareRoot()
            frames.append((Double(start + window / 2) / sampleRate, rms,
                           estimate(x, minLag: minLag, maxLag: maxLag, sampleRate: sampleRate)))
            start += hop
        }
        let loudest = frames.map(\.rms).max() ?? 0
        let gate = max(0.002, loudest * 0.12)
        var voiced: [(time: Double, f0: Double)] = frames.compactMap { frame in
            guard frame.rms >= gate, let f0 = frame.f0 else { return nil }
            return (frame.time, f0)
        }
        // Mediana de 3 para quitar saltos de octava aislados.
        if voiced.count >= 3 {
            var smoothed = voiced
            for i in 1..<(voiced.count - 1) {
                smoothed[i].f0 = median([voiced[i - 1].f0, voiced[i].f0, voiced[i + 1].f0])
            }
            voiced = smoothed
        }
        return voiced
    }

    static func estimate(_ x: [Float], minLag: Int, maxLag: Int, sampleRate: Double) -> Double? {
        let length = x.count - maxLag
        guard length > 16, minLag < maxLag else { return nil }
        var values = [Float](repeating: 0, count: maxLag + 2)
        var best: Float = 0
        var bestLag = 0
        for lag in minLag...maxLag {
            var cross: Float = 0, a: Float = 0, b: Float = 0
            for i in 0..<length {
                let p = x[i], q = x[i + lag]
                cross += p * q; a += p * p; b += q * q
            }
            let denominator = (a * b).squareRoot()
            let r = denominator > 0 ? cross / denominator : 0
            values[lag] = r
            if r > best { best = r; bestLag = lag }
        }
        guard best >= 0.6, bestLag > 0 else { return nil }
        // El periodo real es el retardo más corto con una correlación casi igual
        // (evita confundir la voz con su octava inferior).
        for lag in minLag..<bestLag where values[lag] >= best * 0.9
            && values[lag] >= values[lag - 1] && values[lag] >= values[lag + 1] {
            bestLag = lag
            break
        }
        var refined = Double(bestLag)
        if bestLag > minLag && bestLag < maxLag {
            let a = values[bestLag - 1], b = values[bestLag], c = values[bestLag + 1]
            let curvature = a - 2 * b + c
            if curvature != 0 { refined += Double(0.5 * (a - c) / curvature) }
        }
        return refined > 0 ? sampleRate / refined : nil
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

enum QuestionMarks {
    /// Convierte en pregunta la última frase del fragmento: «Vienes mañana.» → «¿Vienes mañana?».
    /// No toca exclamaciones, puntos suspensivos ni fragmentos que acaban en coma.
    static func markLastSentence(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastCharacter = body.last, body.contains(where: \.isLetter) else { return text }
        if lastCharacter == "!" || lastCharacter == "…" || body.hasSuffix("...") { return text }
        if lastCharacter == "." || lastCharacter == "?" {
            body.removeLast()
        } else if !(lastCharacter.isLetter || lastCharacter.isNumber) {
            return text
        }
        var start = body.startIndex
        if let boundary = body.lastIndex(where: { ".?!…\n".contains($0) }) {
            start = body.index(after: boundary)
        }
        while start < body.endIndex, body[start].isWhitespace { start = body.index(after: start) }
        guard start < body.endIndex else { return text }
        if !body[start...].contains("¿") { body.insert("¿", at: start) }
        return body + "?"
    }
}
