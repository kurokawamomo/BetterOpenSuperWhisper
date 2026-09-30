import AVFoundation
import Combine
import Foundation
import Speech
import os

/// Drives ONE live-preview transcription session. Implementations receive raw
/// microphone buffers as they arrive during recording and report partial text as
/// it becomes available. Completely independent of the final batch transcription
/// path (`TranscriptionService`): a live engine's failure never affects it, and
/// vice versa.
protocol LivePreviewEngine: AnyObject {
    func start(onPartialText: @escaping (String) -> Void)
    func appendAudio(_ buffer: AVAudioPCMBuffer)
    func stop()
}

/// Keeps only the most recent `maxDuration` of microphone buffers. Holds the
/// audio recorded while the live-preview engine cannot exist yet (the model is
/// still loading) so the engine can catch up once it does. The buffers are the
/// immutable copies the recorder already makes, so nothing is duplicated.
struct LiveAudioCatchUpBuffer {
    let maxDuration: TimeInterval
    private(set) var buffers: [AVAudioPCMBuffer] = []
    private(set) var duration: TimeInterval = 0

    init(maxDuration: TimeInterval) {
        self.maxDuration = maxDuration
    }

    private static func duration(of buffer: AVAudioPCMBuffer) -> TimeInterval {
        Double(buffer.frameLength) / buffer.format.sampleRate
    }

    mutating func append(_ buffer: AVAudioPCMBuffer) {
        buffers.append(buffer)
        duration += Self.duration(of: buffer)
        while duration > maxDuration, buffers.count > 1 {
            duration -= Self.duration(of: buffers.removeFirst())
        }
    }
}

/// Orchestrates the live-preview engine for the current recording. Owns no audio
/// capture itself: `AudioRecorder` fans out the same buffers it already taps for
/// the final recording into `appendLiveAudio`, keyed by the recording's session ID
/// (the same one `RecordingSessionController`/`IndicatorViewModel` already use), so
/// a stale/cancelled session's buffers are dropped rather than leaking into the
/// next recording's preview.
@MainActor
final class AudioTranscriptionManager: ObservableObject {
    static let shared = AudioTranscriptionManager()

    @Published private(set) var partialText: String?

    // `appendLiveAudio` is called directly from the AVAudioEngine tap thread (not
    // the main actor) so a live-preview chunk is handed off with no main-thread
    // round trip. These two are the only state it touches, so they're guarded by
    // a lock instead of actor isolation (same pattern as `AbortFlag` elsewhere).
    private let stateLock = NSLock()
    private nonisolated(unsafe) var activeSessionID: UUID?
    private nonisolated(unsafe) var engine: LivePreviewEngine?
    /// Set while a Whisper preview is waiting for the model to finish loading: the
    /// session is active but has no engine yet, so its audio is kept here instead of
    /// being dropped. Guarded by `stateLock` like the two above.
    private nonisolated(unsafe) var waitingForModel: LiveAudioCatchUpBuffer?

    private var batchBusyCancellable: AnyCancellable?
    private var modelLoadCancellable: AnyCancellable?

    private init() {}

    func startLivePreview(sessionID: UUID) {
        partialText = nil

        guard AppPreferences.shared.livePreviewEnabled else {
            print("[LivePreview][diag] startLivePreview(\(sessionID)): livePreviewEnabled=false, skipping")
            return
        }

        print("[LivePreview][diag] startLivePreview(\(sessionID)): enabled, engine=\(AppPreferences.shared.livePreviewEngine)")

        let newEngine: LivePreviewEngine?
        switch AppPreferences.shared.livePreviewEngine {
        case "whisper":
            if let whisperLiveEngine = makeWhisperEngine() {
                newEngine = whisperLiveEngine
            } else if TranscriptionService.shared.isLoading {
                // The model is still loading (the first recording after an idle
                // release): keep the audio and start the preview the moment the
                // load finishes, rather than giving up for the whole recording.
                deferUntilModelLoads(sessionID: sessionID)
                return
            } else {
                print("[LivePreview] whisper selected, but the active batch engine isn't Whisper (likely Parakeet) — skipping live preview for this recording rather than loading a second model")
                newEngine = nil
            }
        default:
            newEngine = AppleLivePreviewEngine()
        }

        guard let newEngine else {
            print("[LivePreview][diag] startLivePreview(\(sessionID)): no engine constructed, live preview inactive for this recording")
            return
        }

        stateLock.lock()
        activeSessionID = sessionID
        engine = newEngine
        stateLock.unlock()

        print("[LivePreview][diag] startLivePreview(\(sessionID)): engine=\(type(of: newEngine)) armed")

        begin(newEngine, sessionID: sessionID)
    }

    private func makeWhisperEngine() -> WhisperLivePreviewEngine? {
        guard let whisperEngine = TranscriptionService.shared.whisperEngineForLivePreview,
              let liveEngine = WhisperLivePreviewEngine(whisperEngine: whisperEngine) else { return nil }
        // The final batch pass must never wait on (or be slowed down by) a
        // live-preview decode sharing the same model weights, so the live
        // loop skips its tick whenever a batch transcription is in flight.
        batchBusyCancellable = TranscriptionService.shared.$isTranscribing
            .sink { [weak liveEngine] busy in
                liveEngine?.setBatchBusy(busy)
            }
        return liveEngine
    }

    private func begin(_ newEngine: LivePreviewEngine, sessionID: UUID) {
        newEngine.start { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.stateLock.lock()
                let isActive = self.activeSessionID == sessionID
                self.stateLock.unlock()
                print("[LivePreview][diag] partial text for \(sessionID) (isActive=\(isActive)): \"\(text)\"")
                LivePreviewLog.logger.notice("partial text (active=\(isActive, privacy: .public)): \(text.count, privacy: .public) chars")
                guard isActive else { return }
                self.partialText = text
            }
        }
    }

    private func deferUntilModelLoads(sessionID: UUID) {
        stateLock.lock()
        activeSessionID = sessionID
        waitingForModel = LiveAudioCatchUpBuffer(maxDuration: WhisperLivePreviewEngine.catchUpDuration)
        stateLock.unlock()
        LivePreviewLog.logger.notice("live preview deferred: the model is still loading")
        // Publishes after `currentEngine` is installed, on the main actor.
        modelLoadCancellable = TranscriptionService.shared.engineDidLoad
            .first()
            .sink { [weak self] in self?.startAfterModelLoad(sessionID: sessionID) }
    }

    private func startAfterModelLoad(sessionID: UUID) {
        modelLoadCancellable = nil
        stateLock.lock()
        let stillWaiting = activeSessionID == sessionID && waitingForModel != nil
        stateLock.unlock()
        guard stillWaiting else { return }

        guard let liveEngine = makeWhisperEngine() else {
            // The loaded engine isn't Whisper (e.g. Parakeet): nothing to attach to.
            stateLock.lock()
            if activeSessionID == sessionID { waitingForModel = nil }
            stateLock.unlock()
            LivePreviewLog.logger.notice("live preview not started after the load: the loaded engine is not Whisper")
            return
        }
        begin(liveEngine, sessionID: sessionID)

        // Install the engine and hand it the earlier audio under the same lock the
        // tap thread uses, so live buffers arriving meanwhile queue up strictly
        // after the catch-up audio.
        stateLock.lock()
        guard activeSessionID == sessionID, let caughtUp = waitingForModel else {
            stateLock.unlock()
            liveEngine.stop()
            return
        }
        waitingForModel = nil
        engine = liveEngine
        liveEngine.prime(caughtUp.buffers)
        stateLock.unlock()
        LivePreviewLog.logger.notice("live preview started after the model loaded; caught up \(String(format: "%.2f", caughtUp.duration), privacy: .public)s of audio (\(caughtUp.buffers.count, privacy: .public) buffers)")
    }

    private nonisolated(unsafe) var didLogFirstBuffer = false

    nonisolated func appendLiveAudio(_ buffer: AVAudioPCMBuffer, sessionID: UUID) {
        stateLock.lock()
        let isActive = activeSessionID == sessionID
        let currentEngine = engine
        if isActive, currentEngine == nil {
            waitingForModel?.append(buffer)
        }
        stateLock.unlock()
        if !didLogFirstBuffer {
            didLogFirstBuffer = true
            print("[LivePreview][diag] appendLiveAudio(\(sessionID)): isActive=\(isActive), format=\(buffer.format)")
        }
        guard isActive else { return }
        currentEngine?.appendAudio(buffer)
    }

    func stopLivePreview(sessionID: UUID) {
        stateLock.lock()
        guard activeSessionID == sessionID else {
            stateLock.unlock()
            return
        }
        let stoppingEngine = engine
        let neverStarted = waitingForModel != nil
        activeSessionID = nil
        engine = nil
        waitingForModel = nil
        stateLock.unlock()

        modelLoadCancellable = nil
        if neverStarted {
            LivePreviewLog.logger.notice("live preview never started: the recording ended before the model finished loading")
        }
        batchBusyCancellable = nil
        stoppingEngine?.stop()
        partialText = nil
        didLogFirstBuffer = false
    }
}

/// Apple's on-device speech recognizer. Partial results are a native feature here,
/// so this engine is little more than wiring — and a completely separate path from
/// Whisper, its output never touches the final batch pass.
final class AppleLivePreviewEngine: LivePreviewEngine {
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onPartialText: ((String) -> Void)?

    func start(onPartialText: @escaping (String) -> Void) {
        self.onPartialText = onPartialText
        print("[LivePreview][apple][diag] requesting speech recognition authorization")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            print("[LivePreview][apple][diag] authorization status=\(status.rawValue)")
            guard status == .authorized else {
                print("[LivePreview][apple] speech recognition authorization not granted (\(status.rawValue))")
                return
            }
            DispatchQueue.main.async { self?.beginRecognitionIfNeeded() }
        }
    }

    private func beginRecognitionIfNeeded() {
        guard task == nil, let recognizer, recognizer.isAvailable else {
            print("[LivePreview][apple] recognizer unavailable for this locale/session (recognizer=\(String(describing: recognizer)), isAvailable=\(recognizer?.isAvailable ?? false))")
            return
        }
        print("[LivePreview][apple][diag] recognition task starting, onDeviceSupported=\(recognizer.supportsOnDeviceRecognition)")
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                self?.onPartialText?(result.bestTranscription.formattedString)
            }
            if let error {
                print("[LivePreview][apple] recognition error: \(error.localizedDescription)")
            }
        }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func stop() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        onPartialText = nil
    }
}

/// A hand-rolled equivalent of whisper.cpp's classic `examples/stream`: repeatedly
/// re-decodes the trailing few seconds of audio against the SAME already-loaded
/// model — a second, independent `whisper_state` (see
/// `MyWhisperContext.makeSecondaryState()`) — so this needs no additional
/// native/bridge work and no second model load. `noContext` stays true so each
/// window decodes independently: a hallucination on one window's audio cannot
/// poison the next, at the cost of the sentence-level continuity the final batch
/// pass gets via `prompt_past` — live preview does not need that.
final class WhisperLivePreviewEngine: LivePreviewEngine {
    private static let windowDuration: TimeInterval = 4.0
    private static let stepDuration: TimeInterval = 1.2
    private static let sampleRate: Double = 16000

    /// Weak on purpose: a live-preview engine must never extend the model's lifetime.
    /// If it held the context strongly, a lingering instance would keep the weights
    /// alive after an idle release (whisper_free would never run). A decode that
    /// finds the context gone simply does nothing.
    private weak var context: MyWhisperContext?
    private var state: OpaquePointer?
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    private let queue = DispatchQueue(label: "com.opensuperwhisper.livepreview.whisper", qos: .userInitiated)
    private var pendingSamples: [Float] = []
    private var samplesSinceLastDecode = 0
    private var isDecoding = false
    private var onPartialText: ((String) -> Void)?
    private var lastEmittedText = ""

    private let busyLock = NSLock()
    private var isBatchBusy = false

    init?(whisperEngine: WhisperEngine) {
        guard let sharedContext = whisperEngine.contextForLivePreview,
              let secondaryState = sharedContext.makeSecondaryState(),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        else {
            print("[LivePreview][whisper][diag] init failed (contextForLivePreview or makeSecondaryState returned nil)")
            return nil
        }
        context = sharedContext
        state = secondaryState
        targetFormat = format
        print("[LivePreview][whisper][diag] secondary state created on shared context")
    }

    deinit {
        IdleUnloadLog.logger.notice("WhisperLivePreviewEngine deinit")
    }

    func setBatchBusy(_ busy: Bool) {
        busyLock.lock()
        isBatchBusy = busy
        busyLock.unlock()
    }

    func start(onPartialText: @escaping (String) -> Void) {
        queue.async { [weak self] in
            self?.onPartialText = onPartialText
        }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.handle(buffer: buffer)
        }
    }

    /// How much earlier audio a late-started preview is worth catching up on: the
    /// engine only ever keeps this trailing window, so anything older would be
    /// dropped on arrival.
    static var catchUpDuration: TimeInterval { windowDuration }

    /// Takes in audio that was recorded before this engine existed (the model was
    /// still loading), without decoding along the way. Decoding once per step while
    /// replaying would queue several decodes ahead of the live audio; instead the
    /// window is filled and exactly one decode is due on the next live buffer.
    func prime(_ buffers: [AVAudioPCMBuffer]) {
        queue.async { [weak self] in
            guard let self, self.state != nil else { return }
            for buffer in buffers {
                _ = self.ingest(buffer)
            }
            let windowSamples = Int(Self.windowDuration * Self.sampleRate)
            if self.pendingSamples.count > windowSamples {
                self.pendingSamples.removeFirst(self.pendingSamples.count - windowSamples)
            }
            self.samplesSinceLastDecode = Int(Self.stepDuration * Self.sampleRate)
            LivePreviewLog.logger.notice("live preview primed with \(String(format: "%.2f", Double(self.pendingSamples.count) / Self.sampleRate), privacy: .public)s of earlier audio from \(buffers.count, privacy: .public) buffers")
        }
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard state != nil, ingest(buffer) else { return }

        let stepSamples = Int(Self.stepDuration * Self.sampleRate)
        guard samplesSinceLastDecode >= stepSamples, !isDecoding else { return }
        samplesSinceLastDecode = 0
        decodeCurrentWindow()
    }

    /// Converts to 16 kHz mono and appends to the window. False if nothing came out.
    private func ingest(_ buffer: AVAudioPCMBuffer) -> Bool {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        }
        guard let converter else { return false }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return false }

        var consumed = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, outBuffer.frameLength > 0, let channelData = outBuffer.floatChannelData else { return false }

        let newSamples = UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength))
        pendingSamples.append(contentsOf: newSamples)
        samplesSinceLastDecode += newSamples.count
        return true
    }

    private func decodeCurrentWindow() {
        // Held strongly for the duration of one decode so the context cannot be
        // freed underneath a running whisper_full_with_state.
        guard let state, let context else { return }

        let windowSamples = Int(Self.windowDuration * Self.sampleRate)
        if pendingSamples.count > windowSamples {
            pendingSamples.removeFirst(pendingSamples.count - windowSamples)
        }
        let chunk = pendingSamples
        guard !chunk.isEmpty else { return }

        busyLock.lock()
        let busy = isBatchBusy
        busyLock.unlock()
        guard !busy else {
            print("[LivePreview][whisper][diag] skipping tick: batch transcription in flight")
            return
        }

        isDecoding = true
        defer { isDecoding = false }

        var params = WhisperFullParams()
        params.strategy = .greedy
        params.nThreads = Int32(max(2, min(ProcessInfo.processInfo.activeProcessorCount / 2, 4)))
        params.noContext = true
        params.noTimestamps = true
        params.suppressBlank = true
        params.greedyBestOf = 1
        params.temperature = 0
        let language = AppPreferences.shared.whisperLanguage
        params.language = language == "auto" ? nil : language
        var cParams = params.toC()

        guard context.full(samples: chunk, params: &cParams, state: state) else {
            print("[LivePreview][whisper][diag] decode of \(chunk.count) samples failed")
            return
        }

        var text = ""
        let nSegments = context.fullNSegments(state: state)
        for i in 0..<nSegments {
            text += context.fullGetSegmentText(state: state, iSegment: i) ?? ""
        }
        text = text
            .replacingOccurrences(of: "[MUSIC]", with: "")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty, text != lastEmittedText else { return }
        lastEmittedText = text
        onPartialText?(text)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if let state = self.state {
                MyWhisperContext.freeSecondaryState(state)
            }
            self.state = nil
            self.pendingSamples.removeAll()
            self.onPartialText = nil
        }
    }
}
