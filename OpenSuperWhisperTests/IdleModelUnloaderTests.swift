import XCTest
@testable import OpenSuperWhisper

final class IdleModelUnloaderRuleTests: XCTestCase {
    private let quiet = IdleModelUnloader.Snapshot(
        isEngineLoaded: true,
        isEngineInUse: false,
        hasRecordingSession: false,
        isQueueProcessing: false,
        hasPendingRecordings: false
    )

    func testReleasesWhenLoadedAndNothingIsHappening() {
        XCTAssertTrue(IdleModelUnloader.canUnload(quiet))
    }

    func testKeepsWhenNothingIsLoaded() {
        var snapshot = quiet
        snapshot.isEngineLoaded = false
        XCTAssertFalse(IdleModelUnloader.canUnload(snapshot))
    }

    func testKeepsWhileTheEngineIsInUse() {
        var snapshot = quiet
        snapshot.isEngineInUse = true
        XCTAssertFalse(IdleModelUnloader.canUnload(snapshot))
    }

    func testKeepsDuringARecordingSession() {
        var snapshot = quiet
        snapshot.hasRecordingSession = true
        XCTAssertFalse(IdleModelUnloader.canUnload(snapshot))
    }

    func testKeepsWhileTheQueueIsProcessing() {
        var snapshot = quiet
        snapshot.isQueueProcessing = true
        XCTAssertFalse(IdleModelUnloader.canUnload(snapshot))
    }

    func testKeepsWhileRecordingsAreWaitingInTheQueue() {
        var snapshot = quiet
        snapshot.hasPendingRecordings = true
        XCTAssertFalse(IdleModelUnloader.canUnload(snapshot))
    }

    func testIdleIntervalIsClampedToTheSupportedRange() {
        XCTAssertEqual(IdleModelUnloader.idleInterval(minutes: 0), 60)
        XCTAssertEqual(IdleModelUnloader.idleInterval(minutes: 1), 60)
        XCTAssertEqual(IdleModelUnloader.idleInterval(minutes: 5), 300)
        XCTAssertEqual(IdleModelUnloader.idleInterval(minutes: 30), 1800)
        XCTAssertEqual(IdleModelUnloader.idleInterval(minutes: 999), 1800)
    }
}

final class UnloadSpyEngine: TranscriptionEngine {
    var isModelLoaded: Bool { true }
    var engineName: String { "Spy" }

    private let lock = NSLock()
    private var unloads = 0
    var unloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unloads
    }

    func initialize() async throws {}
    func unload() {
        lock.lock()
        unloads += 1
        lock.unlock()
    }
    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { ["en"] }
    func transcribeAudio(url: URL, settings: Settings) async throws -> String { "spy" }
}

actor SpyEngineFactory {
    private(set) var engines: [UnloadSpyEngine] = []
    var failNext = false

    func make() throws -> UnloadSpyEngine {
        if failNext { throw TranscriptionError.contextInitializationFailed }
        let engine = UnloadSpyEngine()
        engines.append(engine)
        return engine
    }

    func setFailNext(_ value: Bool) { failNext = value }
}

@MainActor
final class EngineUnloadTests: XCTestCase {
    let selection = TranscriptionService.EngineSelection(engine: "A", modelPath: nil, modelVersion: "v3")
    let url = URL(fileURLWithPath: "/unused.wav")

    func waitUntil(_ description: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    func makeLoadedService(_ factory: SpyEngineFactory) async throws -> TranscriptionService {
        let service = TranscriptionService(
            selection: selection,
            loadOnInit: true,
            engineLoader: { _ in try await factory.make() }
        )
        try await waitUntil("initial load") { service.isEngineLoaded }
        return service
    }

    func testUnloadFreesTheEngineAndEnsureLoadsItAgain() async throws {
        let factory = SpyEngineFactory()
        let service = try await makeLoadedService(factory)

        XCTAssertTrue(service.unloadEngine())
        XCTAssertFalse(service.isEngineLoaded)
        let loadedEngines = await factory.engines
        let first = try XCTUnwrap(loadedEngines.first)
        try await waitUntil("engine unload") { first.unloadCount == 1 }

        service.ensureEngineLoaded()
        try await waitUntil("reload") { service.isEngineLoaded }
        let loads = await factory.engines.count
        XCTAssertEqual(loads, 2)
    }

    func testNothingIsLoadedAtInitWhenDisabled() async throws {
        let factory = SpyEngineFactory()
        let service = TranscriptionService(
            selection: selection,
            loadOnInit: false,
            engineLoader: { _ in try await factory.make() }
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(service.isEngineLoaded)
        XCTAssertFalse(service.isLoading)
        let loads = await factory.engines.count
        XCTAssertEqual(loads, 0)

        service.ensureEngineLoaded()
        try await waitUntil("first load on demand") { service.isEngineLoaded }
    }

    func testUnloadIsRefusedWhileTheEngineIsLoading() async throws {
        let gate = EngineLoadGate()
        let service = TranscriptionService(
            selection: selection,
            loadOnInit: true,
            engineLoader: { try await gate.load($0) }
        )
        try await waitUntil("loader called") { await gate.hasRequest("A") }
        XCTAssertFalse(service.unloadEngine())
        await gate.finish("A", result: .success(NamedTestEngine("A")))
        try await waitUntil("load finished") { service.isEngineLoaded }
        XCTAssertTrue(service.unloadEngine())
    }

    func testTranscriptionAfterUnloadReloadsInsteadOfFailing() async throws {
        let factory = SpyEngineFactory()
        let service = try await makeLoadedService(factory)
        XCTAssertTrue(service.unloadEngine())

        let text = try await service.transcribeAudio(url: url, settings: Settings())

        XCTAssertEqual(text, "spy")
        let loads = await factory.engines.count
        XCTAssertEqual(loads, 2)
    }

    func testEnsureDoesNotRetryAfterAFailedLoad() async throws {
        let factory = SpyEngineFactory()
        await factory.setFailNext(true)
        let service = TranscriptionService(
            selection: selection,
            loadOnInit: true,
            engineLoader: { _ in try await factory.make() }
        )
        try await waitUntil("load failure") { service.loadingError != nil }

        await factory.setFailNext(false)
        service.ensureEngineLoaded()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(service.isEngineLoaded)
        let loads = await factory.engines.count
        XCTAssertEqual(loads, 0)
    }
}
