import Foundation
import Network

/// Sürücüden gelen sesi UDP ile bir hedefe (iPad) yayınlayan `AudioSink`.
///
/// Gecikmeyi düşük tutmak için:
/// - Paketler küçüktür (256 kare ≈ 48 kHz'de 5,3 ms); paketleme en fazla bir
///   paket süresi bekletir.
/// - `serviceClass = .interactiveVoice`: paketler Wi-Fi'de WMM "voice"
///   kuyruğundan (DSCP EF) gider; yoğun ağda en düşük kuyruk gecikmesi.
/// - `allowFastOpen`: bağlantı kurulumunu beklemeden ilk veriye izin verir
///   (UDP'de kurulum zaten anlıktır; esas olarak TCP/QUIC için anlamlıdır).
/// - Bağlantı `.ready` olmadan gönderilen paketler kuyruğa alınmaz, atılır;
///   böylece ağ geri geldiğinde eski ses birikmiş olarak gönderilmez.
/// - Gönderim, motorun ses kuyruğunda ek bir iş parçacığı geçişi olmadan yapılır.
public final class UDPAudioSender: AudioSink {
    public enum State: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
    }

    public struct Stats: Equatable {
        public var packetsSent: UInt64 = 0
        public var bytesSent: UInt64 = 0
        public var sendErrors: UInt64 = 0
        /// Son gönderim hatası ve zamanı (systemUptime). Hedef port kapalıysa
        /// iPad "port unreachable" döndürür ve burada "Connection refused" görülür.
        public var lastError: String?
        public var lastErrorUptime: TimeInterval = 0
        public var sampleRate: Double = 0
    }

    /// Durum değişiklikleri ana kuyrukta bildirilir.
    public var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "com.mylifer.airspeaker.udp", qos: .userInteractive)
    // connection, isReady, packetizer ve stats bu kilitle korunur: start/stop
    // ana iş parçacığından, receive motor kuyruğundan, durum geri çağrıları
    // `queue`'dan gelir.
    private let lock = NSLock()
    private var connection: NWConnection?
    private var isReady = false
    private var packetizer = AudioPacketizer()
    private var stats = Stats()

    public init() {}

    public static func makeParameters() -> NWParameters {
        let udp = NWProtocolUDP.Options()
        let parameters = NWParameters(dtls: nil, udp: udp)
        parameters.serviceClass = .interactiveVoice
        parameters.allowFastOpen = true
        parameters.preferNoProxies = true
        return parameters
    }

    /// Yayını başlatır. Önceki bir yayın varsa önce durdurulur.
    public func start(host: String, port: UInt16) {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            report(.failed("Geçersiz port: \(port)"))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                      using: Self.makeParameters())
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.handle(state, of: connection)
        }

        lock.lock()
        self.connection = connection
        isReady = false
        packetizer.reset()
        stats = Stats()
        lock.unlock()

        report(.connecting)
        connection.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let connection = self.connection
        self.connection = nil
        isReady = false
        lock.unlock()

        guard let connection else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        report(.idle)
    }

    public func currentStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    // MARK: - AudioSink

    public func receive(samples: UnsafeBufferPointer<Float>, frameCount: Int, channelCount: Int, sampleRate: Double) {
        var packets: [Data] = []
        lock.lock()
        guard let connection, isReady else {
            lock.unlock()
            return
        }
        stats.sampleRate = sampleRate
        packetizer.append(samples, frameCount: frameCount, channelCount: channelCount, sampleRate: sampleRate) {
            packets.append($0)
        }
        lock.unlock()

        guard !packets.isEmpty else { return }
        connection.batch {
            for packet in packets {
                let size = packet.count
                connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                    self?.didSend(bytes: size, error: error)
                })
            }
        }
    }

    // MARK: - Özel

    private func didSend(bytes: Int, error: NWError?) {
        lock.lock()
        defer { lock.unlock() }
        if let error {
            stats.sendErrors += 1
            stats.lastError = Self.describe(error)
            stats.lastErrorUptime = ProcessInfo.processInfo.systemUptime
        } else {
            stats.packetsSent += 1
            stats.bytesSent += UInt64(bytes)
        }
    }

    private func handle(_ state: NWConnection.State, of connection: NWConnection) {
        lock.lock()
        let isCurrent = connection === self.connection
        if isCurrent {
            isReady = state == .ready
        }
        lock.unlock()
        guard isCurrent else { return }

        switch state {
        case .setup, .preparing:
            report(.connecting)
        case .ready:
            report(.ready)
        case .waiting(let error):
            // Ağ yolu yok (ör. Wi-Fi kapalı); Network framework kendisi yeniden dener.
            report(.failed("Ağ bekleniyor: \(Self.describe(error))"))
        case .failed(let error):
            report(.failed(Self.describe(error)))
            lock.lock()
            if self.connection === connection {
                self.connection = nil
            }
            lock.unlock()
            connection.cancel()
        case .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return "Hedef bu portu dinlemiyor (bağlantı reddedildi)"
        case .posix(let code) where code == .EHOSTUNREACH || code == .ENETUNREACH:
            return "Hedefe ulaşılamıyor (aynı ağda mı?)"
        case .dns:
            return "Adres çözümlenemedi"
        default:
            return error.localizedDescription
        }
    }
}
