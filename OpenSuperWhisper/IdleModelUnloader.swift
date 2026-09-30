import Combine
import Foundation

/// Decides when the loaded model may be released after a stretch of inactivity.
/// It owns only the timing and the "is it safe right now" judgement; holding
/// and freeing the engine stays in `TranscriptionService`, so the service and
/// the queue need no knowledge of each other's idleness.
@MainActor
final class IdleModelUnloader {
    static let shared = IdleModelUnloader()

    nonisolated static let minimumMinutes = 1
    nonisolated static let maximumMinutes = 30

    /// Everything the release decision depends on, as a plain value so the rule
    /// can be tested without the live singletons.
    struct Snapshot: Equatable {
        var isEngineLoaded: Bool
        var isEngineInUse: Bool
        var hasRecordingSession: Bool
        var isQueueProcessing: Bool
        var hasPendingRecordings: Bool
    }

    nonisolated static func canUnload(_ snapshot: Snapshot) -> Bool {
        snapshot.isEngineLoaded
            && !snapshot.isEngineInUse
            && !snapshot.hasRecordingSession
            && !snapshot.isQueueProcessing
            && !snapshot.hasPendingRecordings
    }

    nonisolated static func idleInterval(minutes: Int) -> TimeInterval {
        TimeInterval(min(max(minutes, minimumMinutes), maximumMinutes) * 60)
    }

    private let service: TranscriptionService
    private let queue: TranscriptionQueue
    private let recordingStore: RecordingStore
    private var timer: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        service: TranscriptionService = .shared,
        queue: TranscriptionQueue = .shared,
        recordingStore: RecordingStore = .shared
    ) {
        self.service = service
        self.queue = queue
        self.recordingStore = recordingStore
    }

    func start() {
        guard cancellables.isEmpty else { return }

        service.$isTranscribing.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.activityChanged() }
            .store(in: &cancellables)
        service.$isLoading.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.activityChanged() }
            .store(in: &cancellables)
        queue.$isProcessing.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.activityChanged() }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        center.publisher(for: .indicatorWindowWillShow)
            .sink { [weak self] _ in self?.cancelTimer() }
            .store(in: &cancellables)
        center.publisher(for: .indicatorWindowDidHide)
            .sink { [weak self] _ in self?.activityChanged() }
            .store(in: &cancellables)
        center.publisher(for: .idleUnloadSettingsChanged)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)

        activityChanged()
    }

    private func settingsChanged() {
        // Turning the option off restores the always-loaded behaviour.
        if !AppPreferences.shared.unloadModelWhenIdle {
            service.ensureEngineLoaded()
        }
        activityChanged()
    }

    /// Any change in what the app is doing restarts the countdown, so the timer
    /// always measures time since the last activity.
    private func activityChanged() {
        cancelTimer()
        guard AppPreferences.shared.unloadModelWhenIdle else { return }
        scheduleTimer()
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func scheduleTimer() {
        let interval = Self.idleInterval(minutes: AppPreferences.shared.unloadModelIdleMinutes)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timerFired()
        }
    }

    private func timerFired() {
        guard AppPreferences.shared.unloadModelWhenIdle else { return }
        let snapshot = makeSnapshot()
        // Nothing loaded: the next load completing restarts the countdown.
        guard snapshot.isEngineLoaded else { return }
        if Self.canUnload(snapshot), service.unloadEngine() {
            print("IdleModelUnloader: released the model after \(AppPreferences.shared.unloadModelIdleMinutes) min idle")
            return
        }
        scheduleTimer()
    }

    private func makeSnapshot() -> Snapshot {
        // If the pending list can't be read, assume there is work: never release
        // a model that a queued recording may be waiting on.
        let hasPending = (try? recordingStore.getPendingRecordings().isEmpty == false) ?? true
        return Snapshot(
            isEngineLoaded: service.isEngineLoaded,
            isEngineInUse: service.isEngineInUse,
            hasRecordingSession: RecordingSessionController.shared.hasSession,
            isQueueProcessing: queue.isProcessing,
            hasPendingRecordings: hasPending
        )
    }
}
