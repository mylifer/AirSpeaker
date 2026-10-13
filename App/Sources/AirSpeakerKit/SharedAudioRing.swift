import CAirSpeakerIPC
import Darwin
import XPC

/// Sürücünün paylaştığı halka tamponun bu süreçteki eşlemesi.
public final class SharedAudioRing {
    public static let channelCount = Int(AIRSPEAKER_RING_CHANNELS)

    let header: UnsafePointer<AirSpeakerRingHeader>
    private let region: UnsafeMutableRawPointer
    private let size: Int

    /// Broker'dan gelen xpc_shmem nesnesini eşler; bölge geçerli bir AirSpeaker
    /// halka tamponu değilse nil döner.
    init?(shmem: xpc_object_t) {
        var mapped: UnsafeMutableRawPointer?
        let size = xpc_shmem_map(shmem, &mapped)
        guard size > 0, let mapped else { return nil }
        guard let header = airspeaker_ring_validate(mapped, size) else {
            munmap(mapped, size)
            return nil
        }
        self.region = mapped
        self.size = size
        self.header = header
    }

    deinit {
        munmap(region, size)
    }

    public var sampleRate: Double { Double(airspeaker_ring_sample_rate(header)) }

    /// Sürücünün bugüne kadar yazdığı toplam kare sayısı.
    public var writeFrame: UInt64 { airspeaker_ring_write_frame(header) }
}

/// Halka tamponu kendi konumuyla okuyan tek bir okuyucu. Thread-safe değildir;
/// tek bir kuyruktan kullanılmalıdır.
public final class SharedRingReader {
    public let ring: SharedAudioRing
    public private(set) var droppedFrames: UInt64 = 0

    private var readFrame: UInt64
    private var scratch: [Float]
    private let maxFramesPerRead: Int

    public init(ring: SharedAudioRing, maxFramesPerRead: Int = 4096) {
        self.ring = ring
        self.maxFramesPerRead = maxFramesPerRead
        self.scratch = [Float](repeating: 0, count: maxFramesPerRead * SharedAudioRing.channelCount)
        // Geçmişi değil, canlı sesi oku.
        self.readFrame = ring.writeFrame
    }

    /// Okunabilir tüm kareleri parça parça `body`'ye verir (interleaved Float32).
    /// Okunan toplam kare sayısını döndürür.
    @discardableResult
    public func drain(_ body: (UnsafeBufferPointer<Float>, Int) -> Void) -> Int {
        let channels = SharedAudioRing.channelCount
        var total = 0
        while true {
            let frames = scratch.withUnsafeMutableBufferPointer { buffer -> Int in
                let count = Int(airspeaker_ring_read(ring.header, &readFrame, buffer.baseAddress,
                                                     UInt32(maxFramesPerRead), &droppedFrames))
                if count > 0 {
                    body(UnsafeBufferPointer(rebasing: buffer[0..<(count * channels)]), count)
                }
                return count
            }
            if frames == 0 {
                return total
            }
            total += frames
        }
    }
}
