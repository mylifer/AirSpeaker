// AirSpeaker — iPad alıcısı (Swift Playgrounds "Uygulama" projesi, tek dosya)
//
// Mac'teki AirSpeaker menü çubuğu uygulamasının UDP ile yayınladığı sesi alır
// ve AVAudioEngine + AVAudioPlayerNode ile çalar.
//
// KULLANIM
// 1. iPad'de Swift Playgrounds'u açın, "+" ile yeni bir *Uygulama* (App) oluşturun.
// 2. Soldaki dosya listesinde "MyApp" (Uygulamam) dosyasını açın, içindeki her
//    şeyi silip bu dosyanın tamamını yapıştırın. "ContentView" dosyasına
//    dokunmanıza gerek yok; kullanılmaz.
// 3. Uygulamayı çalıştırın (▶). Yerel ağ izni sorulursa "İzin Ver" deyin.
//    Uzun dinlemelerde ekran kararmasın diye Ayarlar › Ekran ve Parlaklık ›
//    Otomatik Kilit'i "Hiçbir Zaman" yapın.
// 4. Ekranda görünen IP adresini Mac'teki AirSpeaker menüsüne girin (port 5000)
//    ve "Yayını Başlat"a basın.
//
// Paket biçimi Mac tarafındaki App/Sources/AirSpeakerKit/AudioPacket.swift ile
// aynıdır; birinde değişiklik yaparsanız diğerini de güncelleyin.

import AVFoundation
import Network
import SwiftUI

// MARK: - Uygulama

@main
struct AirSpeakerReceiverApp: App {
    @StateObject private var model = ReceiverViewModel()

    var body: some Scene {
        WindowGroup {
            ReceiverView(model: model)
        }
    }
}

// MARK: - Paket biçimi (Mac ile aynı)

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
struct AudioPacketHeader: Equatable {
    static let magic: [UInt8] = Array("ASPK".utf8)
    static let size = 28
    static let currentVersion: UInt8 = 1

    enum Format: UInt8 {
        case pcmInt16 = 1

        var bytesPerSample: Int {
            switch self {
            case .pcmInt16: return 2
            }
        }
    }

    var format: Format
    var channelCount: UInt8
    var sampleRate: UInt32
    var sequence: UInt32
    var frameIndex: UInt64
    var frameCount: UInt16

    var payloadSize: Int {
        Int(frameCount) * Int(channelCount) * format.bytesPerSample
    }

    /// Bir paketin başlığını çözer; paket geçersizse veya yük eksikse nil döner.
    static func decode(_ packet: Data) -> AudioPacketHeader? {
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

// MARK: - Alıcı: UDP dinleyici + titreşim tamponu + ses motoru

/// UDP 5000'i dinler, paketleri çözer ve küçük, kendini ayarlayan bir titreşim
/// (jitter) tamponu üzerinden AVAudioPlayerNode'a verir.
///
/// Titreşim tamponu, oynatıcıya sıraya alınmış paket sayısıyla ölçülür
/// (1 paket = 256 kare ≈ 48 kHz'de 5,3 ms):
/// - Başlangıçta `targetDepth` kadar paket birikince çalmaya başlar (≈ 21 ms).
/// - Tampon boşalırsa (çatlama) hedef bir paket büyür ve yeniden doldurulur.
/// - Uzun süre çatlama olmazsa hedef yavaşça küçülür; gecikme yeniden azalır.
/// - Kuyruk sürekli hedefin üstündeyse (saat kayması, ağ patlaması) arada bir
///   paket atlanarak gecikmenin birikmesi önlenir.
final class AirSpeakerReceiver: @unchecked Sendable {
    struct Snapshot: Equatable {
        var listening = false
        var error: String?
        var isReceiving = false
        var sender: String?
        var sampleRate: Double = 0
        var packets: UInt64 = 0
        var lostPackets: UInt64 = 0
        var latePackets: UInt64 = 0
        var trimmedPackets: UInt64 = 0
        var underruns: UInt64 = 0
        var bufferMs: Double = 0
        var targetMs: Double = 0
        var peak: Float = 0
    }

    let port: UInt16

    // Titreşim tamponu ayarları (paket cinsinden).
    private let initialDepth = 4
    private let minDepth = 2
    private let maxDepth = 24
    private let maxConcealedGap: UInt32 = 8

    // Ağ ve ses işleri bu seri kuyrukta yapılır.
    private let queue = DispatchQueue(label: "airspeaker.receiver", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isPlayerAttached = false
    private var format: AVAudioFormat?

    private var expectedSequence: UInt32?
    private var generation = 0
    private var scheduledCount = 0
    private var prebuffer: [AVAudioPCMBuffer] = []
    private var isPrimed = false
    private var targetDepth: Int
    private var lastUnderrunUptime: TimeInterval = 0
    private var windowStartUptime: TimeInterval = 0
    private var windowMinimum = Int.max
    private var lastPacketFrames = 256

    // Arayüzün okuduğu istatistikler; kilitle korunur.
    private let lock = NSLock()
    private var stats = Snapshot()
    private var lastPacketUptime: TimeInterval = 0

    init(port: UInt16 = 5000) {
        self.port = port
        self.targetDepth = initialDepth
    }

    func start() {
        configureAudioSession()
        observeAudioSystemChanges()
        queue.async { self.startListener() }
    }

    /// Arayüz için anlık durum; tepe seviyesi her okumada sıfırlanır.
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = stats
        snapshot.isReceiving = ProcessInfo.processInfo.systemUptime - lastPacketUptime < 0.5
        stats.peak = 0
        return snapshot
    }

    // MARK: Ağ

    private func startListener() {
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVoice
        parameters.allowLocalEndpointReuse = true

        guard let endpointPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: parameters, on: endpointPort)
        else {
            updateStats { $0.error = "UDP \(self.port) portu açılamadı" }
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.updateStats {
                    $0.listening = true
                    $0.error = nil
                }
            case .waiting(let error):
                self.updateStats { $0.error = "Ağ bekleniyor: \(error.localizedDescription)" }
            case .failed(let error):
                self.updateStats {
                    $0.listening = false
                    $0.error = "Dinleyici hatası: \(error.localizedDescription)"
                }
                listener?.cancel()
                self.queue.asyncAfter(deadline: .now() + 2) { self.startListener() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ newConnection: NWConnection) {
        // Tek gönderici: yeni bir gönderici gelirse eskisini bırak.
        connection?.cancel()
        connection = newConnection
        expectedSequence = nil
        resetJitterBuffer()

        var senderName = "\(newConnection.endpoint)"
        if case .hostPort(let host, _) = newConnection.endpoint {
            senderName = "\(host)"
        }
        updateStats { $0.sender = senderName }

        newConnection.start(queue: queue)
        receive(on: newConnection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                self.handle(packet: data)
            }
            if error == nil && connection.state != .cancelled {
                self.receive(on: connection)
            }
        }
    }

    // MARK: Paket işleme

    private func handle(packet: Data) {
        guard let header = AudioPacketHeader.decode(packet), header.frameCount > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // Sıra numarası: kayıp ve geç gelen paketleri ayıkla.
        var missingPackets: UInt32 = 0
        if let expected = expectedSequence {
            let gap = header.sequence &- expected
            if gap >= UInt32.max / 2 {
                let behind = expected &- header.sequence
                if behind < 1000 {
                    // Zamanı geçmiş paket; çalmak gecikme yaratır, at.
                    updateStats { $0.latePackets += 1 }
                    return
                }
                // Çok gerideyse gönderici yeni bir akış başlatmıştır.
                resetJitterBuffer()
            } else if gap > 0 {
                missingPackets = gap
            }
        }
        expectedSequence = header.sequence &+ 1

        guard let format = ensureEngine(sampleRate: Double(header.sampleRate)) else { return }

        // Birkaç paketlik kaybı sessizlikle doldur; zamanlama kaymasın.
        if missingPackets > 0 && missingPackets <= maxConcealedGap {
            for _ in 0..<missingPackets {
                if let silence = makeSilence(frames: header.frameCount, format: format) {
                    enqueue(silence, now: now)
                }
            }
        }

        guard let converted = makeBuffer(from: packet, header: header, format: format) else { return }
        let (buffer, peak) = converted
        lastPacketFrames = Int(header.frameCount)
        enqueue(buffer, now: now)

        let frameMs = Double(lastPacketFrames) / format.sampleRate * 1000
        let depth = isPrimed ? scheduledCount : prebuffer.count
        let target = targetDepth
        lock.lock()
        lastPacketUptime = now
        stats.packets += 1
        stats.lostPackets += UInt64(missingPackets)
        stats.sampleRate = format.sampleRate
        stats.peak = max(stats.peak, peak)
        stats.bufferMs = Double(depth) * frameMs
        stats.targetMs = Double(target) * frameMs
        lock.unlock()
    }

    private func makeBuffer(from packet: Data, header: AudioPacketHeader,
                            format: AVAudioFormat) -> (AVAudioPCMBuffer, Float)? {
        let frames = Int(header.frameCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = channels[0]
        let right = channels[1]
        let sourceChannels = Int(header.channelCount)
        let bytesPerFrame = sourceChannels * 2
        var peak: Float = 0

        packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            func sample(at offset: Int) -> Float {
                Float(Int16(bitPattern: UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8)) / 32768
            }
            for frame in 0..<frames {
                let offset = AudioPacketHeader.size + frame * bytesPerFrame
                let l = sample(at: offset)
                let r = sourceChannels > 1 ? sample(at: offset + 2) : l
                left[frame] = l
                right[frame] = r
                peak = max(peak, abs(l), abs(r))
            }
        }
        return (buffer, peak)
    }

    private func makeSilence(frames: UInt16, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            channels[channel].initialize(repeating: 0, count: Int(frames))
        }
        return buffer
    }

    // MARK: Titreşim tamponu

    private func enqueue(_ buffer: AVAudioPCMBuffer, now: TimeInterval) {
        if !isPrimed {
            prebuffer.append(buffer)
            if prebuffer.count >= targetDepth {
                isPrimed = true
                windowStartUptime = now
                windowMinimum = Int.max
                prebuffer.forEach(schedule)
                prebuffer.removeAll()
                if !player.isPlaying {
                    player.play()
                }
            }
            return
        }

        // Güvenlik sınırı: kuyruk aşırı uzadıysa paketi atla.
        if scheduledCount >= maxDepth + 4 {
            updateStats { $0.trimmedPackets += 1 }
            return
        }

        // Kuyruğun son 2 sn'deki en düşük seviyesi hedefin üstündeyse gereksiz
        // gecikme var: bir paket atla. Uzun süredir çatlama yoksa hedefi küçült.
        windowMinimum = min(windowMinimum, scheduledCount)
        if now - windowStartUptime >= 2 {
            let excess = windowMinimum > targetDepth
            windowStartUptime = now
            windowMinimum = Int.max
            if now - lastUnderrunUptime > 20 && targetDepth > minDepth {
                targetDepth -= 1
                lastUnderrunUptime = now
            }
            if excess {
                updateStats { $0.trimmedPackets += 1 }
                return
            }
        }
        schedule(buffer)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        scheduledCount += 1
        let bufferGeneration = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.bufferRendered(generation: bufferGeneration) }
        }
    }

    private func bufferRendered(generation bufferGeneration: Int) {
        guard bufferGeneration == generation else { return }
        scheduledCount = max(0, scheduledCount - 1)
        guard scheduledCount == 0, isPrimed else { return }

        // Tampon boşaldı. Akış sürüyorsa bu bir çatlamadır: hedefi büyüt.
        // Akış durduysa (Mac'te ses yok) yalnızca yeniden doldurmaya geç.
        isPrimed = false
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let streamActive = now - lastPacketUptime < 0.1
        lock.unlock()
        if streamActive {
            targetDepth = min(targetDepth + 1, maxDepth)
            lastUnderrunUptime = now
            updateStats { $0.underruns += 1 }
        }
    }

    private func resetJitterBuffer() {
        generation += 1
        scheduledCount = 0
        prebuffer.removeAll()
        isPrimed = false
        windowMinimum = Int.max
    }

    // MARK: Ses motoru

    /// Motoru gelen örnekleme hızına göre (yeniden) yapılandırır. iPad'in donanım
    /// hızı farklıysa ana mikser dönüştürür.
    private func ensureEngine(sampleRate: Double) -> AVAudioFormat? {
        if let format, format.sampleRate == sampleRate, engine.isRunning {
            return format
        }
        guard sampleRate > 0,
              let newFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        else { return nil }

        resetJitterBuffer()
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        if !isPlayerAttached {
            engine.attach(player)
            isPlayerAttached = true
        }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: newFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            updateStats { $0.error = "Ses motoru başlatılamadı: \(error.localizedDescription)" }
            format = nil
            return nil
        }
        format = newFormat
        updateStats { $0.error = nil }
        return newFormat
    }

    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredSampleRate(48_000)
            // Donanım G/Ç tamponu ~5 ms: çıkış gecikmesini en aza indirir.
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            updateStats { $0.error = "Ses oturumu açılamadı: \(error.localizedDescription)" }
        }
        #endif
    }

    /// Kulaklık takılıp çıkarılması, AirPods, kesinti (arama) gibi durumlarda
    /// motor durur; bir sonraki pakette yeniden kurulur.
    private func observeAudioSystemChanges() {
        let center = NotificationCenter.default
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.format = nil }
        }
        #if os(iOS)
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.queue.async { self.format = nil }
        }
        #endif
    }

    private func updateStats(_ body: (inout Snapshot) -> Void) {
        lock.lock()
        body(&stats)
        lock.unlock()
    }
}

// MARK: - Wi-Fi IP adresi

enum NetworkInfo {
    /// iPad'in yerel ağdaki IPv4 adresi (öncelik Wi-Fi: en0).
    static func localIPAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = pointer.pointee.ifa_flags
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                candidates.append((String(cString: pointer.pointee.ifa_name), String(cString: host)))
            }
        }
        return candidates.first { $0.name == "en0" }?.address
            ?? candidates.first { $0.name.hasPrefix("en") }?.address
            ?? candidates.first?.address
    }
}

// MARK: - Arayüz

@MainActor
final class ReceiverViewModel: ObservableObject {
    @Published private(set) var snapshot = AirSpeakerReceiver.Snapshot()
    @Published private(set) var ipAddress: String?
    @Published private(set) var level: Float = 0

    let receiver = AirSpeakerReceiver(port: 5000)
    private let pathMonitor = NWPathMonitor()

    init() {
        receiver.start()
        ipAddress = NetworkInfo.localIPAddress()
        // Wi-Fi değiştiğinde gösterilen IP adresini güncelle.
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.ipAddress = NetworkInfo.localIPAddress() }
        }
        pathMonitor.start(queue: .main)
    }

    /// Ana iş parçacığında, zamanlayıcıyla çağrılır.
    func refresh() {
        let newSnapshot = receiver.snapshot()
        // Seviye göstergesi: hızlı yüksel, yavaş düş.
        level = max(newSnapshot.isReceiving ? newSnapshot.peak : 0, level * 0.85)
        if newSnapshot != snapshot {
            snapshot = newSnapshot
        }
    }
}

struct ReceiverView: View {
    @ObservedObject var model: ReceiverViewModel
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.10),
                                    Color(red: 0.10, green: 0.12, blue: 0.20)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                VStack(spacing: 8) {
                    Image(systemName: "hifispeaker.2.fill")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("AirSpeaker")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("iPad Alıcısı")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.6))
                }

                StatusBadge(isReceiving: model.snapshot.isReceiving, error: model.snapshot.error)

                LevelMeter(level: model.level)
                    .frame(height: 8)
                    .opacity(model.snapshot.isReceiving ? 1 : 0.25)

                AddressCard(ipAddress: model.ipAddress, port: model.receiver.port)

                StatsRow(snapshot: model.snapshot)
            }
            .padding(36)
            .frame(maxWidth: 560)
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .onReceive(ticker) { _ in model.refresh() }
    }
}

struct StatusBadge: View {
    let isReceiving: Bool
    let error: String?
    @State private var pulse = false

    private var color: Color {
        if error != nil { return .red }
        return isReceiving ? .green : .orange
    }

    private var title: String {
        if error != nil { return "Hata" }
        return isReceiving ? "Ses Alınıyor 🟢" : "Bağlantı Bekleniyor..."
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.45))
                        .frame(width: 30, height: 30)
                        .scaleEffect(pulse ? 1.5 : 0.7)
                        .opacity(pulse ? 0 : 1)
                    Circle()
                        .fill(color)
                        .frame(width: 14, height: 14)
                }
                .frame(width: 30, height: 30)
                Text(title)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
            .animation(.easeInOut(duration: 0.3), value: isReceiving)

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .orange],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}

struct AddressCard: View {
    let ipAddress: String?
    let port: UInt16

    var body: some View {
        VStack(spacing: 10) {
            Text("Mac'teki AirSpeaker menüsüne girin")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
            if let ipAddress {
                Text(ipAddress)
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("Port \(String(port))")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Label("Wi-Fi bağlantısı yok", systemImage: "wifi.slash")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.1)))
    }
}

struct StatsRow: View {
    let snapshot: AirSpeakerReceiver.Snapshot

    var body: some View {
        HStack(spacing: 12) {
            stat("Tampon", snapshot.packets > 0
                 ? "\(Int(snapshot.bufferMs.rounded())) / \(Int(snapshot.targetMs.rounded())) ms" : "—")
            stat("Biçim", snapshot.sampleRate > 0 ? "\(Int(snapshot.sampleRate / 1000)) kHz" : "—")
            stat("Kayıp", "\(snapshot.lostPackets + snapshot.latePackets)")
            stat("Çatlama", "\(snapshot.underruns)")
        }
        .overlay(alignment: .bottom) {
            if let sender = snapshot.sender {
                Text("Gönderen: \(sender)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .offset(y: 28)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
