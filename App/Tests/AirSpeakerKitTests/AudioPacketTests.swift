@testable import AirSpeakerKit
import XCTest

final class AudioPacketTests: XCTestCase {
    func testHeaderRoundTrip() throws {
        let header = AudioPacketHeader(channelCount: 2, sampleRate: 48000, sequence: 0xDEADBEEF,
                                       frameIndex: 0x0102_0304_0506_0708, frameCount: 3)
        var data = Data()
        header.encode(into: &data)
        XCTAssertEqual(data.count, AudioPacketHeader.size)
        XCTAssertEqual(Array(data.prefix(4)), Array("ASPK".utf8))
        // Little-endian kontrolü: sampleRate 48000 = 0x0000BB80
        XCTAssertEqual(Array(data[8..<12]), [0x80, 0xBB, 0x00, 0x00])

        data.append(contentsOf: [UInt8](repeating: 0, count: header.payloadSize))
        XCTAssertEqual(AudioPacketHeader.decode(data), header)
    }

    func testDecodeRejectsInvalidPackets() {
        XCTAssertNil(AudioPacketHeader.decode(Data()))
        XCTAssertNil(AudioPacketHeader.decode(Data(repeating: 0, count: 64)))

        let header = AudioPacketHeader(channelCount: 2, sampleRate: 48000, sequence: 0, frameIndex: 0,
                                       frameCount: 10)
        var truncated = Data()
        header.encode(into: &truncated)
        truncated.append(contentsOf: [UInt8](repeating: 0, count: header.payloadSize - 1))
        XCTAssertNil(AudioPacketHeader.decode(truncated), "eksik yük kabul edilmemeli")
    }

    func testFloatToInt16Conversion() {
        XCTAssertEqual(AudioPacketizer.int16(from: 0), 0)
        XCTAssertEqual(AudioPacketizer.int16(from: 1), Int16.max)
        XCTAssertEqual(AudioPacketizer.int16(from: -1), -Int16.max)
        XCTAssertEqual(AudioPacketizer.int16(from: 2), Int16.max, "taşma kırpılmalı")
        XCTAssertEqual(AudioPacketizer.int16(from: -2), -Int16.max)
        XCTAssertEqual(AudioPacketizer.int16(from: .nan), 0)
        XCTAssertEqual(AudioPacketizer.int16(from: 0.5), 16384)
    }

    func testPacketizerSplitsIntoFixedSizePackets() {
        var packetizer = AudioPacketizer(framesPerPacket: 4)
        var packets: [Data] = []
        // 10 kare stereo: 4 + 4 dolu paket, 2 kare beklemede kalır.
        let samples = (0..<20).map { Float($0) / 100 }
        samples.withUnsafeBufferPointer { buffer in
            packetizer.append(buffer, frameCount: 10, channelCount: 2, sampleRate: 48000) { packets.append($0) }
        }
        XCTAssertEqual(packets.count, 2)

        let headers = packets.compactMap(AudioPacketHeader.decode)
        XCTAssertEqual(headers.map(\.sequence), [0, 1])
        XCTAssertEqual(headers.map(\.frameIndex), [0, 4])
        XCTAssertEqual(headers.map(\.frameCount), [4, 4])
        XCTAssertEqual(headers[0].samples(in: packets[0]),
                       (0..<8).map { AudioPacketizer.int16(from: Float($0) / 100) })

        // Kalan 2 kare + yeni 2 kare = bir dolu paket; sıra ve konum devam eder.
        let more = (20..<24).map { Float($0) / 100 }
        more.withUnsafeBufferPointer { buffer in
            packetizer.append(buffer, frameCount: 2, channelCount: 2, sampleRate: 48000) { packets.append($0) }
        }
        XCTAssertEqual(packets.count, 3)
        let third = AudioPacketHeader.decode(packets[2])
        XCTAssertEqual(third?.sequence, 2)
        XCTAssertEqual(third?.frameIndex, 8)
        XCTAssertEqual(third.map { $0.samples(in: packets[2]) },
                       (16..<24).map { AudioPacketizer.int16(from: Float($0) / 100) })
    }

    func testSampleRateChangeFlushesPartialPacket() {
        var packetizer = AudioPacketizer(framesPerPacket: 4)
        var packets: [Data] = []
        let samples = [Float](repeating: 0.1, count: 4)  // 2 kare
        samples.withUnsafeBufferPointer { buffer in
            packetizer.append(buffer, frameCount: 2, channelCount: 2, sampleRate: 48000) { packets.append($0) }
            packetizer.append(buffer, frameCount: 2, channelCount: 2, sampleRate: 44100) { packets.append($0) }
        }
        XCTAssertEqual(packets.count, 1)
        let header = AudioPacketHeader.decode(packets[0])
        XCTAssertEqual(header?.sampleRate, 48000)
        XCTAssertEqual(header?.frameCount, 2)

        packetizer.flush { packets.append($0) }
        XCTAssertEqual(AudioPacketHeader.decode(packets[1])?.sampleRate, 44100)
        XCTAssertEqual(AudioPacketHeader.decode(packets[1])?.frameIndex, 2)
    }

    func testDefaultPacketFitsInEthernetMTU() {
        let header = AudioPacketHeader(channelCount: 2, sampleRate: 48000, sequence: 0, frameIndex: 0,
                                       frameCount: UInt16(AudioPacketizer.defaultFramesPerPacket))
        // IPv4 (20) + UDP (8) başlıklarıyla 1500 baytlık MTU'ya sığmalı.
        XCTAssertLessThanOrEqual(AudioPacketHeader.size + header.payloadSize + 28, 1500)
    }
}
