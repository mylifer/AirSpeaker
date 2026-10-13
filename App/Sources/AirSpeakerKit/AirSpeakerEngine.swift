import Dispatch
import Foundation

/// Sürücüden gelen PCM verisini alan tüketici. Aşama 3'te UDP göndericisi
/// bu protokolü uygulayacak.
public protocol AudioSink: AnyObject {
    /// `samples`: interleaved Float32, `frameCount * channelCount` öğe. Tampon
    /// yalnızca çağrı süresince geçerlidir. Motorun iç kuyruğunda çağrılır.
    func receive(samples: UnsafeBufferPointer<Float>, frameCount: Int, channelCount: Int, sampleRate: Double)
}

/// Bağlantı durumu; menü çubuğundaki gösterge buna göre renklenir.
public enum LinkStatus: Equatable {
    /// Broker'a ulaşılamıyor.
    case brokerUnavailable(String)
    /// Broker çalışıyor ama sürücü kayıtlı değil.
    case driverOffline
    /// Sürücü bağlı, ancak şu an ses akmıyor (cihaz seçili değil veya çalan bir şey yok).
    case idle
    /// Ses akıyor.
    case streaming
}

public struct EngineSnapshot: Equatable {
    public var status: LinkStatus = .brokerUnavailable("Bağlanıyor…")
    public var sampleRate: Double = 0
    public var receivedFrames: UInt64 = 0
    public var droppedFrames: UInt64 = 0
    /// Son yayın aralığındaki en yüksek mutlak örnek değeri (0…1+).
    public var peak: Float = 0

    public init() {}
}

/// Broker bağlantısını ve paylaşımlı bellek okuyucusunu yöneten motor.
///
/// Tüm iş tek bir seri kuyrukta yapılır: XPC olayları, halka tamponun
/// periyodik okunması (5 ms) ve `AudioSink` çağrıları.
public final class AirSpeakerEngine {
    /// Durum özeti her `snapshotInterval`'da bir ana kuyrukta yayınlanır.
    public var onSnapshot: ((EngineSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "com.mylifer.airspeaker.engine", qos: .userInteractive)
    private let pollInterval: DispatchTimeInterval = .milliseconds(5)
    private let snapshotInterval: DispatchTimeInterval = .milliseconds(250)
    /// Bu süre boyunca yeni kare gelmezse durum `idle` olur.
    private let idleTimeout: TimeInterval = 0.5

    private lazy var broker = BrokerClient(queue: queue)
    private var sink: AudioSink?
    private var reader: SharedRingReader?
    private var pollTimer: DispatchSourceTimer?
    private var snapshotTimer: DispatchSourceTimer?

    private var linkStatus: LinkStatus = .brokerUnavailable("Bağlanıyor…")
    private var receivedFrames: UInt64 = 0
    private var droppedFramesBeforeReader: UInt64 = 0
    private var intervalPeak: Float = 0
    private var lastAudioUptime: TimeInterval = 0

    public init() {}

    public func setSink(_ sink: AudioSink?) {
        queue.async { self.sink = sink }
    }

    public func start() {
        queue.async { [self] in
            broker.onEvent = { [weak self] event in self?.handle(event) }
            broker.start()
            startTimers()
        }
    }

    /// Anlık durum (eşzamanlı; ana iş parçacığından çağrılabilir).
    public func currentSnapshot() -> EngineSnapshot {
        queue.sync { makeSnapshot(resetPeak: false) }
    }

    // MARK: - Broker olayları

    private func handle(_ event: BrokerClient.Event) {
        switch event {
        case .brokerUnavailable(let reason):
            detachReader()
            linkStatus = .brokerUnavailable(reason)
        case .driverOffline:
            detachReader()
            linkStatus = .driverOffline
        case .driverOnline(let ring):
            detachReader()
            reader = SharedRingReader(ring: ring)
            linkStatus = .idle
        }
        publishSnapshot()
    }

    private func detachReader() {
        if let reader {
            droppedFramesBeforeReader += reader.droppedFrames
        }
        reader = nil
    }

    // MARK: - Okuma

    private func startTimers() {
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(1))
        poll.setEventHandler { [weak self] in self?.poll() }
        poll.resume()
        pollTimer = poll

        let snapshot = DispatchSource.makeTimerSource(queue: queue)
        snapshot.schedule(deadline: .now() + snapshotInterval, repeating: snapshotInterval)
        snapshot.setEventHandler { [weak self] in self?.publishSnapshot() }
        snapshot.resume()
        snapshotTimer = snapshot
    }

    private func poll() {
        guard let reader else { return }
        let sampleRate = reader.ring.sampleRate
        let channels = SharedAudioRing.channelCount
        let frames = reader.drain { samples, frameCount in
            var peak = intervalPeak
            for sample in samples {
                peak = max(peak, abs(sample))
            }
            intervalPeak = peak
            sink?.receive(samples: samples, frameCount: frameCount, channelCount: channels, sampleRate: sampleRate)
        }
        if frames > 0 {
            receivedFrames += UInt64(frames)
            lastAudioUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    // MARK: - Durum

    private func makeSnapshot(resetPeak: Bool) -> EngineSnapshot {
        var snapshot = EngineSnapshot()
        if let reader {
            let streaming = ProcessInfo.processInfo.systemUptime - lastAudioUptime < idleTimeout
            snapshot.status = streaming ? .streaming : .idle
            snapshot.sampleRate = reader.ring.sampleRate
        } else {
            snapshot.status = linkStatus
        }
        snapshot.receivedFrames = receivedFrames
        snapshot.droppedFrames = droppedFramesBeforeReader + (reader?.droppedFrames ?? 0)
        snapshot.peak = intervalPeak
        if resetPeak {
            intervalPeak = 0
        }
        return snapshot
    }

    private func publishSnapshot() {
        let snapshot = makeSnapshot(resetPeak: true)
        if let onSnapshot {
            DispatchQueue.main.async { onSnapshot(snapshot) }
        }
    }
}
