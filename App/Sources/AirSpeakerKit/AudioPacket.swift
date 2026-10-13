import Foundation

/// UDP ses paketinin başlığı. Tüm alanlar little-endian'dır.
///
/// ```
/// bayt  alan          tür     açıklama
///  0    magic         4 bayt  "ASPK"
///  4    version       UInt8   1
///  5    format        UInt8   1 = PCM signed 16-bit little-endian, interleaved
///  6    channelCount  UInt8   2
///  7    reserved      UInt8   0
///  8    sampleRate    UInt32  Hz (ör. 48000)
/// 12    sequence      UInt32  her pakette 1 artar (kayıp tespiti; taşınca sarar)
/// 16    frameIndex    UInt64  paketin ilk karesinin akıştaki konumu
/// 24    frameCount    UInt16  paketteki kare sayısı
/// 26    reserved      UInt16  0
/// 28    PCM verisi    frameCount * channelCount * 2 bayt
/// ```
public struct AudioPacketHeader: Equatable {
    public static let magic: [UInt8] = Array("ASPK".utf8)
    public static let size = 28
    public static let currentVersion: UInt8 = 1

    public enum Format: UInt8 {
        case pcmInt16 = 1

        public var bytesPerSample: Int {
            switch self {
            case .pcmInt16: return 2
            }
        }
    }

    public var format: Format
    public var channelCount: UInt8
    public var sampleRate: UInt32
    public var sequence: UInt32
    public var frameIndex: UInt64
    public var frameCount: UInt16

    public init(format: Format = .pcmInt16, channelCount: UInt8, sampleRate: UInt32, sequence: UInt32,
                frameIndex: UInt64, frameCount: UInt16) {
        self.format = format
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.sequence = sequence
        self.frameIndex = frameIndex
        self.frameCount = frameCount
    }

    public var payloadSize: Int {
        Int(frameCount) * Int(channelCount) * format.bytesPerSample
    }

    public func encode(into data: inout Data) {
        data.append(contentsOf: Self.magic)
        data.append(Self.currentVersion)
        data.append(format.rawValue)
        data.append(channelCount)
        data.append(0)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(frameIndex)
        data.appendLittleEndian(frameCount)
        data.appendLittleEndian(UInt16(0))
    }

    /// Bir paketin başlığını çözer; paket geçersizse veya yük eksikse nil döner.
    public static func decode(_ packet: Data) -> AudioPacketHeader? {
        guard packet.count >= size else { return nil }
        let bytes = [UInt8](packet.prefix(size))
        guard Array(bytes[0..<4]) == magic, bytes[4] == currentVersion,
              let format = Format(rawValue: bytes[5]), bytes[6] > 0
        else { return nil }
        let header = AudioPacketHeader(
            format: format,
            channelCount: bytes[6],
            sampleRate: bytes.readLittleEndian(at: 8),
            sequence: bytes.readLittleEndian(at: 12),
            frameIndex: bytes.readLittleEndian(at: 16),
            frameCount: bytes.readLittleEndian(at: 24))
        guard packet.count >= size + header.payloadSize else { return nil }
        return header
    }

    /// Paketin PCM yükünü (interleaved Int16) döndürür.
    public func samples(in packet: Data) -> [Int16] {
        let payload = [UInt8](packet.dropFirst(Self.size).prefix(payloadSize))
        return stride(from: 0, to: payload.count - 1, by: 2).map {
            Int16(bitPattern: UInt16(payload[$0]) | UInt16(payload[$0 + 1]) << 8)
        }
    }
}

/// Sürücüden gelen Float32 kareleri sabit boyutlu UDP paketlerine böler.
///
/// Varsayılan 256 kare/paket: 48 kHz'de ~5,3 ms ses ve 28 + 1024 baytlık
/// paket. Wi-Fi MTU'sunun (~1500) altında kalır, IP parçalanması olmaz;
/// paketleme gecikmesi en fazla bir paket süresidir.
public struct AudioPacketizer {
    public static let defaultFramesPerPacket = 256

    public let framesPerPacket: Int

    private var pending: [Int16] = []
    private var pendingChannels = 0
    private var pendingSampleRate: UInt32 = 0
    private var sequence: UInt32 = 0
    /// pending'deki ilk karenin akıştaki konumu.
    private var nextFrameIndex: UInt64 = 0

    public init(framesPerPacket: Int = AudioPacketizer.defaultFramesPerPacket) {
        precondition(framesPerPacket > 0 && framesPerPacket <= Int(UInt16.max))
        self.framesPerPacket = framesPerPacket
    }

    /// Akışı baştan başlatır (sıra numarası ve kare konumu sıfırlanır).
    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        pendingChannels = 0
        pendingSampleRate = 0
        sequence = 0
        nextFrameIndex = 0
    }

    /// `samples` (interleaved Float32) içindeki kareleri ekler; dolan her paket
    /// için `emit` çağrılır.
    public mutating func append(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, channelCount: Int,
                                sampleRate: Double, emit: (Data) -> Void) {
        guard frameCount > 0, channelCount > 0, channelCount <= Int(UInt8.max) else { return }
        let rate = UInt32(sampleRate.rounded())
        // Biçim değiştiyse eldeki kısmi paketi eski biçimle gönder.
        if !pending.isEmpty && (rate != pendingSampleRate || channelCount != pendingChannels) {
            flush(emit: emit)
        }
        pendingSampleRate = rate
        pendingChannels = channelCount

        let sampleCount = min(samples.count, frameCount * channelCount)
        pending.reserveCapacity(pending.count + sampleCount)
        for index in 0..<sampleCount {
            pending.append(Self.int16(from: samples[index]))
        }

        let samplesPerPacket = framesPerPacket * channelCount
        var consumed = 0
        while pending.count - consumed >= samplesPerPacket {
            emit(makePacket(samples: pending[consumed..<(consumed + samplesPerPacket)]))
            consumed += samplesPerPacket
        }
        if consumed > 0 {
            pending.removeFirst(consumed)
        }
    }

    /// Eldeki eksik paketi (varsa) hemen gönderir.
    public mutating func flush(emit: (Data) -> Void) {
        guard !pending.isEmpty else { return }
        emit(makePacket(samples: pending[...]))
        pending.removeAll(keepingCapacity: true)
    }

    private mutating func makePacket(samples: ArraySlice<Int16>) -> Data {
        let frames = samples.count / pendingChannels
        let header = AudioPacketHeader(
            channelCount: UInt8(pendingChannels), sampleRate: pendingSampleRate, sequence: sequence,
            frameIndex: nextFrameIndex, frameCount: UInt16(frames))
        var data = Data(capacity: AudioPacketHeader.size + header.payloadSize)
        header.encode(into: &data)
        for sample in samples {
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }
        sequence &+= 1
        nextFrameIndex &+= UInt64(frames)
        return data
    }

    /// [-1, 1] aralığındaki Float örneği Int16'ya çevirir (taşmalar kırpılır).
    static func int16(from sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        let clamped = max(-1, min(1, sample))
        return Int16((clamped * Float(Int16.max)).rounded())
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func readLittleEndian<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(self[offset + index]) << (8 * index)
        }
        return value
    }
}
