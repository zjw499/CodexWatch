import Foundation
import XCTest
@testable import ScribePilot

final class VoiceUploadBufferTests: XCTestCase {
    func testVariableHTTPAcknowledgementLatencyCombinesBacklogWithoutLosingAudio() throws {
        var buffer = VoiceUploadBuffer()
        var expected = Data(), uploaded = Data(), requests = 0
        for index in 0..<60 {
            let packet = Data(repeating: UInt8(index), count: 9600)
            expected.append(packet); XCTAssertTrue(buffer.append(packet))
            // Each acknowledgement takes 600 ms; 200 ms individual uploads
            // would fill the old queue, but three packets share this request.
            if index % 3 == 2 { uploaded.append(try XCTUnwrap(buffer.take())); requests += 1 }
        }
        XCTAssertEqual(uploaded, expected)
        XCTAssertEqual(requests, 20)
        XCTAssertEqual(buffer.peakBytes, 28800)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testOneSecondRequestLimitAndBoundedPendingCapture() throws {
        var buffer = VoiceUploadBuffer()
        for _ in 0..<10 { XCTAssertTrue(buffer.append(Data(repeating: 1, count: 9600))) }
        XCTAssertFalse(buffer.append(Data(repeating: 2, count: 9600)))
        XCTAssertEqual(try XCTUnwrap(buffer.take()).count, 48000)
        XCTAssertEqual(try XCTUnwrap(buffer.take()).count, 48000)
        XCTAssertNil(buffer.take())
        XCTAssertFalse(buffer.append(Data(repeating: 1, count: 48002)))
        XCTAssertFalse(buffer.append(Data(repeating: 1, count: 1)))
    }

    func testMuteClearsUnsentAudioBeforeNewCapture() throws {
        var buffer = VoiceUploadBuffer()
        XCTAssertTrue(buffer.append(Data(repeating: 1, count: 9600)))
        buffer.clear(); XCTAssertNil(buffer.take())
        XCTAssertTrue(buffer.append(Data(repeating: 2, count: 9600)))
        XCTAssertEqual(try XCTUnwrap(buffer.take()), Data(repeating: 2, count: 9600))
    }
}
