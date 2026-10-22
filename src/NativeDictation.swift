import Foundation
import AVFoundation
import Speech
import CoreMedia

enum NativeMicrophoneTap {
    // AVAudioNodeTapBlock lacks @Sendable in the ObjC SDK. Creating it inside a
    // MainActor method otherwise inherits that actor and traps on the audio
    // service queue at the very first hardware buffer in Swift 6.
    nonisolated static func make(consume: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in consume(buffer) }
    }
}

enum NativeDictationError: LocalizedError, Sendable {
    case unavailable
    case unsupportedSpanish
    case incompatibleAudio
    case invalidState
    case microphonePermission
    case audio(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "El reconocimiento nativo no está disponible en este Mac."
        case .unsupportedSpanish: return "No se ha podido preparar el reconocimiento nativo en español de España. Vuelve a intentarlo."
        case .incompatibleAudio: return "No se ha encontrado un formato de audio compatible."
        case .invalidState: return "Esta sesión de dictado ya ha terminado. Prepara una nueva sesión."
        case .microphonePermission: return "Dictado Mac necesita permiso de Micrófono."
        case .audio(let message): return message
        }
    }
}

// Results can become final without being emitted again. Keep the current text for
// every audio range, replacing overlapping revisions instead of appending them.
struct NativeTranscriptAccumulator {
    private struct Segment {
        let start: Double
        let end: Double
        let text: String
    }
    private var segments: [Segment] = []

    mutating func update(text: String, range: CMTimeRange) -> String {
        let start = range.start.seconds
        let end = range.end.seconds
        guard start.isFinite, end.isFinite else { return value }
        segments.removeAll {
            abs($0.start - start) < 0.001 || min($0.end, end) - max($0.start, start) > 0.001
        }
        if !text.isEmpty { segments.append(Segment(start: start, end: end, text: text)) }
        segments.sort { $0.start < $1.start }
        return value
    }

    var value: String { Self.join(segments.map(\.text)) }

    /// Reescribe cada fragmento conociendo dónde acaba en el audio y si es el último.
    func transformed(_ transform: (_ text: String, _ end: Double, _ isLast: Bool) -> String) -> String {
        Self.join(segments.enumerated().map { index, segment in
            transform(segment.text, segment.end, index == segments.count - 1)
        })
    }

    private static func join(_ texts: [String]) -> String {
        texts.reduce(into: "") { combined, text in
            if let last = combined.last, let first = text.first,
               !last.isWhitespace, !first.isWhitespace, !",.;:!?)]}".contains(first) {
                combined += " "
            }
            combined += text
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Copia mono y a unos 16 kHz del audio del micrófono, para analizar la entonación
/// al terminar. Misma línea temporal que el analizador (empieza en el primer búfer).
final class ProsodyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    private var factor = 1
    private var rate: Double = 16_000
    private var carrySum: Float = 0
    private var carryCount = 0
    private let maximumSeconds: Double = 240

    func configure(inputRate: Double) {
        lock.lock(); defer { lock.unlock() }
        factor = max(1, Int(inputRate / 16_000))
        rate = inputRate / Double(factor)
        storage = []
        storage.reserveCapacity(Int(rate * 30))
        carrySum = 0; carryCount = 0
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?.pointee else { return }
        let frames = Int(buffer.frameLength)
        lock.lock(); defer { lock.unlock() }
        guard Double(storage.count) < rate * maximumSeconds else { return }
        for frame in 0..<frames {
            carrySum += channel[frame]
            carryCount += 1
            if carryCount == factor {
                storage.append(carrySum / Float(factor))
                carrySum = 0; carryCount = 0
            }
        }
    }

    var snapshot: (samples: [Float], rate: Double) {
        lock.lock(); defer { lock.unlock() }
        return (storage, rate)
    }
}

// The tap only retains its buffer. Conversion and metering run on this serial
// queue. Both queues have limits: overload is surfaced, never silently dropped.
@available(macOS 26.0, *)
private final class NativeAudioInput: @unchecked Sendable {
    // Ownership passes from the tap to one serial queue. AVAudioConverter invokes
    // its input block synchronously on that same queue, never in parallel.
    private final class OwnedBuffer: @unchecked Sendable {
        let value: AVAudioPCMBuffer
        var supplied = false
        init(_ value: AVAudioPCMBuffer) { self.value = value }
    }
    private let queue = DispatchQueue(label: "es.jorge.dictadomac.native-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var accepting = true
    private var failed = false
    private var pending = 0
    private var acceptedFrames: UInt64 = 0
    private let maximumPending = 32
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Float) -> Void
    private let onError: @Sendable (String) -> Void
    private let prosody: ProsodyRecorder?
    private var lastLevelTime: UInt64 = 0 // Used only on queue.

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat,
         continuation: AsyncStream<AnalyzerInput>.Continuation,
         prosody: ProsodyRecorder? = nil,
         onLevel: @escaping @Sendable (Float) -> Void,
         onError: @escaping @Sendable (String) -> Void) throws {
        self.prosody = prosody
        self.outputFormat = outputFormat
        self.continuation = continuation
        self.onLevel = onLevel
        self.onError = onError
        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let value = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw NativeDictationError.incompatibleAudio
            }
            converter = value
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let retained = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        retained.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(retained.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData else { return nil }
            let count = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            memcpy(to, from, Int(count))
        }
        return retained
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        guard let retained = Self.copy(buffer) else {
            fail("No se ha podido conservar el audio del micrófono.")
            return
        }
        lock.lock()
        guard accepting, !failed else { lock.unlock(); return }
        guard pending < maximumPending else {
            lock.unlock()
            fail("El sistema no puede procesar el audio a tiempo. Se ha detenido el dictado para evitar perder palabras.")
            return
        }
        pending += 1
        acceptedFrames += UInt64(retained.frameLength)
        // Enqueue before releasing the lock: endInput must follow all accepted buffers.
        let owned = OwnedBuffer(retained)
        queue.async { [self] in
            process(owned.value)
            lock.lock(); pending -= 1; lock.unlock()
        }
        lock.unlock()
    }

    func endInput() {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        accepting = false
        queue.async { [self] in
            flushConverter()
            continuation.finish()
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock(); accepting = false; failed = true; lock.unlock()
        continuation.finish()
    }

    private func fail(_ message: String) {
        lock.lock()
        guard !failed else { lock.unlock(); return }
        failed = true; accepting = false
        lock.unlock()
        continuation.finish()
        onError(message)
    }

    private var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    var hasAudio: Bool { lock.lock(); defer { lock.unlock() }; return acceptedFrames > 0 }

    private func emit(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, !hasFailed else { return }
        switch continuation.yield(AnalyzerInput(buffer: buffer)) {
        case .enqueued: break
        case .dropped:
            fail("El reconocimiento nativo se ha retrasado. Se ha detenido el dictado para evitar perder palabras.")
        case .terminated: break
        @unknown default: break
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard !hasFailed else { return }
        prosody?.append(buffer)
        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastLevelTime > 60_000_000 {
            lastLevelTime = now
            if let samples = buffer.floatChannelData?.pointee {
                var energy: Float = 0
                for frame in 0..<Int(buffer.frameLength) { energy += samples[frame] * samples[frame] }
                onLevel(min(1, sqrt(energy / Float(buffer.frameLength)) * 5))
            }
        }
        guard let converter else { emit(buffer); return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            fail("No se ha podido convertir el audio del micrófono."); return
        }
        let source = OwnedBuffer(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if source.supplied { inputStatus.pointee = .noDataNow; return nil }
            source.supplied = true; inputStatus.pointee = .haveData
            return source.value
        }
        guard status != .error, error == nil else {
            fail("Error al convertir el audio: \(error?.localizedDescription ?? "formato incompatible")."); return
        }
        emit(output)
    }

    private func flushConverter() {
        guard let converter, !hasFailed else { return }
        // Deliver the resampler's retained tail, including the last syllable.
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error || error != nil {
                fail("No se ha podido finalizar el audio: \(error?.localizedDescription ?? "error de conversión").")
                return
            }
            emit(output)
            if status == .endOfStream || output.frameLength == 0 { return }
        }
    }
}

// One prepared instance is one utterance. Preparing does not access the mic.
// Model resources stay warm for the next prepared instance in this process.
@available(macOS 26.0, *)
@MainActor final class NativeDictationEngine {
    enum State: Equatable { case ready, recording, finishing, finished, cancelled, failed }

    private(set) var state: State = .ready
    private(set) var latestText = ""
    private(set) var lastError: String?
    private(set) var didReachFinalResult = false
    /// Al terminar, convierte en pregunta la frase cuyo tono sube al final.
    var detectQuestions = true
    private(set) var questionsDetected = 0
    var isRecording: Bool { state == .recording }
    private let prosody = ProsodyRecorder()

    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let analyzerFormat: AVAudioFormat
    private var audioEngine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var input: NativeAudioInput?
    private var tapInstalled = false
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var analysisComplete = false
    private var resultsComplete = false
    private var finishWaiters: [CheckedContinuation<String, Never>] = []
    private var accumulator = NativeTranscriptAccumulator()
    private var textCallback: (@MainActor (String) -> Void)?
    private var levelCallback: (@MainActor (Float) -> Void)?
    private var errorCallback: (@MainActor (String) -> Void)?

    private init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat) {
        self.analyzer = analyzer; self.transcriber = transcriber; self.analyzerFormat = format
    }

    static func prepare(vocabulary: [String]) async throws -> NativeDictationEngine {
        try await prepare(inputFormat: nil, vocabulary: vocabulary)
    }

    static func prepare(inputFormat: AVAudioFormat?, vocabulary: [String]) async throws -> NativeDictationEngine {
        guard SpeechTranscriber.isAvailable else { throw NativeDictationError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "es_ES")) else {
            throw NativeDictationError.unsupportedSpanish
        }
        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat) else {
            throw NativeDictationError.incompatibleAudio
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(vocabulary.filter { !$0.isEmpty }.prefix(100))
        do {
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)
            try Task.checkCancellation()
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return NativeDictationEngine(analyzer: analyzer, transcriber: transcriber, format: format)
    }

    func start(onText: @escaping @MainActor (String) -> Void,
               onLevel: @escaping @MainActor (Float) -> Void,
               onError: (@MainActor (String) -> Void)? = nil) async throws {
        guard state == .ready else { throw NativeDictationError.invalidState }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NativeDictationError.microphonePermission
        }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NativeDictationError.incompatibleAudio }
        do {
            try beginInput(format: format, onText: onText, onLevel: onLevel, onError: onError)
            audioEngine = engine
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.state == .recording else { return }
                    self.fail("Ha cambiado el dispositivo de audio. Vuelve a mantener el atajo para continuar dictando.")
                }
            }
            guard let input else { throw NativeDictationError.incompatibleAudio }
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format,
                block: NativeMicrophoneTap.make { input.append($0) })
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            cancel()
            throw error
        }
    }

    // Deterministic file replay exercises the identical converter and analyzer
    // pipeline, without opening a microphone or needing microphone permission.
    func startForTesting(inputFormat: AVAudioFormat, onText: @escaping @MainActor (String) -> Void,
                         onError: (@MainActor (String) -> Void)? = nil) throws {
        try beginInput(format: inputFormat, onText: onText, onLevel: { _ in }, onError: onError)
    }

    func consume(_ buffer: AVAudioPCMBuffer) throws {
        guard state == .recording, audioEngine == nil, let input else { throw NativeDictationError.invalidState }
        input.append(buffer)
    }

    private func beginInput(format: AVAudioFormat,
                            onText: @escaping @MainActor (String) -> Void,
                            onLevel: @escaping @MainActor (Float) -> Void,
                            onError: (@MainActor (String) -> Void)?) throws {
        guard state == .ready else { throw NativeDictationError.invalidState }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(128))
        prosody.configure(inputRate: format.sampleRate)
        let input = try NativeAudioInput(inputFormat: format, outputFormat: analyzerFormat, continuation: continuation,
            prosody: detectQuestions ? prosody : nil,
            onLevel: { [weak self] level in Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                self.levelCallback?(level)
            } },
            onError: { [weak self] message in Task { @MainActor [weak self] in self?.fail(message) } })
        self.input = input
        textCallback = onText; levelCallback = onLevel; errorCallback = onError
        state = .recording
        let transcriber = self.transcriber
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard let self, self.state == .recording || self.state == .finishing else { return }
                    self.latestText = self.accumulator.update(text: String(result.text.characters), range: result.range)
                    self.textCallback?(self.latestText)
                }
                guard let self else { return }
                self.resultsComplete = true
                self.finishIfComplete()
            } catch is CancellationError {} catch { self?.fail("El reconocimiento nativo se ha detenido: \(error.localizedDescription)") }
        }
        let analyzer = self.analyzer
        analysisTask = Task { [weak self] in
            do {
                if let end = try await analyzer.analyzeSequence(stream) {
                    try Task.checkCancellation()
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                guard let self else { return }
                self.analysisComplete = true
                self.finishIfComplete()
            } catch is CancellationError {} catch { self?.fail("No se ha podido finalizar el dictado: \(error.localizedDescription)") }
        }
    }

    func finish() async -> String {
        if state == .finished || state == .cancelled || state == .failed { return latestText }
        if state == .ready { cancel(); return latestText }
        if state == .recording {
            state = .finishing
            stopMicrophone()
            input?.endInput()
            if input?.hasAudio != true {
                completeFinish(finalized: false)
                return latestText
            }
            // An unstructured deadline resumes callers even if a system service
            // ignores cancellation. A task-group timeout would await that service.
            deadlineTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
                guard let self, self.state == .finishing else { return }
                self.completeFinish(finalized: false)
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if state != .finishing { continuation.resume(returning: latestText) }
                else { finishWaiters.append(continuation); finishIfComplete() }
            }
        } onCancel: { [weak self] in Task { @MainActor [weak self] in self?.cancel() } }
    }

    private func finishIfComplete() {
        guard state == .finishing, analysisComplete, resultsComplete else { return }
        completeFinish(finalized: true)
    }

    private func completeFinish(finalized: Bool) {
        guard state == .finishing else { return }
        didReachFinalResult = finalized
        if detectQuestions { latestText = applyIntonation() }
        state = .finished
        deadlineTask?.cancel(); deadlineTask = nil
        if !finalized { cancelAnalyzer() }
        else { resultTask = nil; analysisTask = nil }
        input = nil
        textCallback = nil; levelCallback = nil; errorCallback = nil
        let waiters = finishWaiters; finishWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: latestText) }
    }

    private func applyIntonation() -> String {
        let (samples, rate) = prosody.snapshot
        guard samples.count > Int(rate) / 4 else { return latestText }
        var marked = 0
        let result = accumulator.transformed { text, end, isLast in
            guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return text }
            // Antes de una pausa a mitad de frase el tono también sube (continuación): no es pregunta.
            guard isLast || last == "." || last == "?" else { return text }
            guard ProsodyAnalyzer.intonation(samples: samples, sampleRate: rate, end: end) == .rising else { return text }
            let question = QuestionMarks.markLastSentence(text)
            if question != text { marked += 1 }
            return question
        }
        questionsDetected = marked
        return result.isEmpty ? latestText : result
    }

    func cancel() {
        guard state != .cancelled, state != .finished, state != .failed else { return }
        state = .cancelled
        stopMicrophone()
        input?.cancel(); input = nil
        deadlineTask?.cancel(); deadlineTask = nil
        cancelAnalyzer()
        textCallback = nil; levelCallback = nil; errorCallback = nil
        let waiters = finishWaiters; finishWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: latestText) }
    }

    private func cancelAnalyzer() {
        resultTask?.cancel(); analysisTask?.cancel()
        resultTask = nil; analysisTask = nil
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func fail(_ message: String) {
        guard state == .recording || state == .finishing else { return }
        let callback = errorCallback
        cancel()
        state = .failed; lastError = message
        callback?(message)
    }

    private func stopMicrophone() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let audioEngine else { return }
        audioEngine.stop()
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        self.audioEngine = nil
    }
}
