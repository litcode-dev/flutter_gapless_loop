import XCTest
import AVFoundation
@testable import flutter_gapless_loop

// MARK: - Helpers

/// Creates a mono float PCM buffer with 10ms-wide amplitude pulses at every beat.
func makePulseBuffer(bpm: Double, sampleRate: Double = 44100, durationSecs: Double = 10.0) -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(sampleRate * durationSecs)
    let format     = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer     = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let data       = buffer.floatChannelData![0]
    let periodSamples = Int(sampleRate * 60.0 / bpm)
    let pulseLen   = Int(sampleRate * 0.01)  // 10ms
    var pos        = 0
    while pos < Int(frameCount) {
        let end = min(pos + pulseLen, Int(frameCount))
        for i in pos ..< end { data[i] = 1.0 }
        pos += periodSamples
    }
    return buffer
}

// MARK: - BpmDetectorTests

class BpmDetectorTests: XCTestCase {

    func testShortAudioReturnsZero() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100   // 1 second — below 2s minimum
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertEqual(result.bpm, 0.0, accuracy: 0.001, "Short audio should return bpm=0")
        XCTAssertTrue(result.beats.isEmpty, "Short audio should return empty beats")
    }

    func testSilenceReturnsZero() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 5)!
        buffer.frameLength = 44100 * 5   // 5 seconds, all zeros
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertEqual(result.bpm, 0.0, accuracy: 0.001, "Silence should return bpm=0")
    }

    func test120BpmWithinTolerance() {
        let buffer = makePulseBuffer(bpm: 120)
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertLessThanOrEqual(abs(result.bpm - 120.0), 2.0,
            "Expected ~120 BPM, got \(result.bpm)")
        XCTAssertGreaterThan(result.confidence, 0.5,
            "Expected confidence > 0.5, got \(result.confidence)")
    }

    func test128BpmWithinTolerance() {
        let buffer = makePulseBuffer(bpm: 128)
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertLessThanOrEqual(abs(result.bpm - 128.0), 2.0,
            "Expected ~128 BPM, got \(result.bpm)")
    }

    func testBeatTimestampsMonotonicallyIncreasing() {
        let buffer = makePulseBuffer(bpm: 120)
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertGreaterThan(result.beats.count, 1, "Expected multiple beats")
        for i in 1 ..< result.beats.count {
            XCTAssertGreaterThan(result.beats[i], result.beats[i - 1],
                "Non-monotonic at index \(i): \(result.beats[i]) <= \(result.beats[i-1])")
        }
    }

    func testNoBeatsInMicroFadeRegion() {
        let buffer = makePulseBuffer(bpm: 120)
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertTrue(result.beats.allSatisfy { $0 >= 0.005 },
            "Found beat in micro-fade region: \(result.beats.filter { $0 < 0.005 })")
    }

    func testConfidenceInRange() {
        let buffer = makePulseBuffer(bpm: 120)
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.0)
        XCTAssertLessThanOrEqual(result.confidence, 1.0)
    }
}
