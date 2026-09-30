import AVFoundation
import XCTest
@testable import OpenSuperWhisper

final class LiveAudioCatchUpBufferTests: XCTestCase {
    private func makeBuffer(frames: AVAudioFrameCount, sampleRate: Double = 16000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return buffer
    }

    func testKeepsEverythingWhileUnderTheLimit() throws {
        var catchUp = LiveAudioCatchUpBuffer(maxDuration: 4)
        for _ in 0..<10 { catchUp.append(try makeBuffer(frames: 1024)) }
        XCTAssertEqual(catchUp.buffers.count, 10)
        XCTAssertEqual(catchUp.duration, 10 * 1024 / 16000, accuracy: 0.0001)
    }

    func testDropsTheOldestAudioBeyondTheLimit() throws {
        var catchUp = LiveAudioCatchUpBuffer(maxDuration: 4)
        for _ in 0..<100 { catchUp.append(try makeBuffer(frames: 1024)) }
        XCTAssertLessThanOrEqual(catchUp.duration, 4)
        XCTAssertGreaterThan(catchUp.duration, 4 - 1024.0 / 16000)
    }

    func testAlwaysKeepsTheNewestBufferEvenIfItAloneExceedsTheLimit() throws {
        var catchUp = LiveAudioCatchUpBuffer(maxDuration: 1)
        catchUp.append(try makeBuffer(frames: 48000))
        XCTAssertEqual(catchUp.buffers.count, 1)
    }

    func testMeasuresDurationInTheBuffersOwnSampleRate() throws {
        var catchUp = LiveAudioCatchUpBuffer(maxDuration: 4)
        catchUp.append(try makeBuffer(frames: 48000, sampleRate: 48000))
        XCTAssertEqual(catchUp.duration, 1, accuracy: 0.0001)
    }
}
