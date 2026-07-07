import XCTest
@testable import VoiceInk

final class MeetingAudioMixerTests: XCTestCase {
    func testMixAveragesAllChannelsToMono() {
        let tap: [[Float]] = [[1, 1], [0, 0]]
        let mic: [[Float]] = [[0.5, 0.5]]
        XCTAssertEqual(MeetingAudioMixer.mixToMono(channelBuffers: tap + mic, frameCount: 2), [0.5, 0.5])
    }
    func testMixHandlesEmptyInput() {
        XCTAssertEqual(MeetingAudioMixer.mixToMono(channelBuffers: [], frameCount: 0), [])
    }
    func testSingleChannelPassthrough() {
        XCTAssertEqual(MeetingAudioMixer.mixToMono(channelBuffers: [[0.25, -0.5]], frameCount: 2), [0.25, -0.5])
    }
}
