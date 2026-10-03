import AVFoundation
import XCTest
@testable import recall

final class BoundedCAFWriterTests: XCTestCase {
    func testRoundTripProducesOpusCAFWithExpectedFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = BoundedCAFWriter(outputURL: url, maxBytes: 1_000_000)
        try writer.start()
        try writer.appendSamples(Array(repeating: Float(0), count: 16_000))
        let result = try writer.finish()

        XCTAssertGreaterThan(result.duration, 0.9)
        XCTAssertEqual(result.fileSize, try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000, accuracy: 0.1)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatOpus)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096)!
        try file.read(into: buffer)
        XCTAssertGreaterThan(buffer.frameLength, 0)
    }

    func testLimitFailureDoesNotAllowFileToGrowPastLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let limit: Int64 = 65_536
        let writer = BoundedCAFWriter(outputURL: url, maxBytes: limit)
        try writer.start()
        var didFail = false
        for chunk in 0..<120 {
            let samples = (0..<4_096).map { index in
                let phase = Double(chunk * 4_096 + index) * 0.071
                return Float(sin(phase) * 0.8)
            }
            do {
                try writer.appendSamples(samples)
            } catch {
                didFail = true
                break
            }
        }
        XCTAssertTrue(didFail)
        XCTAssertThrowsError(try writer.finish())
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        XCTAssertLessThanOrEqual(size, limit)
    }

    func testExistingDestinationIsNeverOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("keep me".utf8)
        try original.write(to: url, options: .completeFileProtection)
        let writer = BoundedCAFWriter(outputURL: url, maxBytes: 1_000_000)
        XCTAssertThrowsError(try writer.start())
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
