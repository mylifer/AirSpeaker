import AirSpeakerKit
import AppKit
import SwiftUI

@main
struct AirSpeakerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            StatusPanel(model: model)
        } label: {
            Image(nsImage: StatusIcon.image(for: model.indicator.level))
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Model

/// Menü çubuğundaki göstergenin seviyesi.
enum IndicatorLevel {
    case active   // yeşil
    case standby  // gri
    case error    // kırmızı
}

struct Indicator: Equatable {
    var level: IndicatorLevel
    var title: String
    var detail: String?
}

@MainActor
final class AppModel: ObservableObject {
    static let defaultPort: UInt16 = 5000
    private enum DefaultsKey {
        static let host = "targetHost"
        static let port = "targetPort"
    }

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: DefaultsKey.host) }
    }
    @Published var portText: String {
        didSet { UserDefaults.standard.set(portText, forKey: DefaultsKey.port) }
    }
    @Published private(set) var isBroadcasting = false
    @Published private(set) var snapshot = EngineSnapshot()
    @Published private(set) var senderState: UDPAudioSender.State = .idle
    @Published private(set) var senderStats = UDPAudioSender.Stats()
    @Published private(set) var validationError: String?

    private let engine = AirSpeakerEngine()
    private let sender = UDPAudioSender()
    /// Son gönderim hatası bu süreden yeniyse gösterge kırmızı olur.
    private let recentErrorWindow: TimeInterval = 2

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: DefaultsKey.host) ?? ""
        portText = defaults.string(forKey: DefaultsKey.port) ?? String(Self.defaultPort)

        // Paketlenmeden (swift run) çalıştırıldığında da Dock simgesi göstermesin.
        NSApplication.shared.setActivationPolicy(.accessory)

        sender.onStateChange = { [weak self] state in
            Task { @MainActor in self?.senderState = state }
        }
        engine.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in self?.update(snapshot) }
        }
        engine.start()
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

    var port: UInt16? {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    var canStart: Bool { !trimmedHost.isEmpty && port != nil }

    func toggleBroadcast() {
        isBroadcasting ? stopBroadcast() : startBroadcast()
    }

    func startBroadcast() {
        guard !trimmedHost.isEmpty, !trimmedHost.contains(" ") else {
            validationError = "Geçerli bir IP adresi girin (ör. 192.168.1.20)."
            return
        }
        guard let port else {
            validationError = "Port 1 ile 65535 arasında olmalı."
            return
        }
        validationError = nil
        sender.start(host: trimmedHost, port: port)
        engine.setSink(sender)
        isBroadcasting = true
    }

    func stopBroadcast() {
        engine.setSink(nil)
        sender.stop()
        isBroadcasting = false
        senderStats = UDPAudioSender.Stats()
    }

    private func update(_ snapshot: EngineSnapshot) {
        if self.snapshot != snapshot {
            self.snapshot = snapshot
        }
        if isBroadcasting {
            let stats = sender.currentStats()
            if senderStats != stats {
                senderStats = stats
            }
        }
    }

    var indicator: Indicator {
        // Sürücü / broker sorunları yayın açık olsun olmasın gösterilir.
        switch snapshot.status {
        case .brokerUnavailable(let reason):
            return Indicator(level: .error, title: "Sürücüye bağlanılamıyor", detail: reason)
        case .driverOffline:
            return Indicator(level: .error, title: "Sürücü çevrimdışı",
                             detail: "coreaudiod yeniden başlıyor olabilir.")
        case .idle, .streaming:
            break
        }

        guard isBroadcasting else {
            return Indicator(level: .standby, title: "Beklemede", detail: nil)
        }

        switch senderState {
        case .idle, .connecting:
            return Indicator(level: .standby, title: "Bağlanıyor…", detail: nil)
        case .failed(let message):
            return Indicator(level: .error, title: "Yayın hatası", detail: message)
        case .ready:
            let now = ProcessInfo.processInfo.systemUptime
            if let error = senderStats.lastError, now - senderStats.lastErrorUptime < recentErrorWindow {
                return Indicator(level: .error, title: "Gönderilemiyor", detail: error)
            }
            if snapshot.status == .streaming {
                return Indicator(level: .active, title: "Yayında", detail: nil)
            }
            return Indicator(level: .active, title: "Yayında — ses yok",
                             detail: "Çıkış olarak “iPad Ses Çıkışı” seçili mi?")
        }
    }
}

// MARK: - Görünüm

struct StatusPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let indicator = model.indicator
        VStack(alignment: .leading, spacing: 12) {
            header(indicator)
            Divider()
            targetForm
            broadcastButton
            if model.isBroadcasting {
                Divider()
                statistics
            }
            Divider()
            HStack {
                Spacer()
                Button("AirSpeaker'dan Çık") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func header(_ indicator: Indicator) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(StatusIcon.color(for: indicator.level))
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("iPad Ses Çıkışı").font(.headline)
                Text(indicator.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let detail = indicator.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(indicator.level == .error ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var targetForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("iPad IP")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    TextField("192.168.1.20", text: $model.host)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if !model.isBroadcasting { model.startBroadcast() } }
                }
                GridRow {
                    Text("Port").foregroundStyle(.secondary)
                    TextField(String(AppModel.defaultPort), text: $model.portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit { if !model.isBroadcasting { model.startBroadcast() } }
                }
            }
            .disabled(model.isBroadcasting)

            if let error = model.validationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var broadcastButton: some View {
        Button {
            model.toggleBroadcast()
        } label: {
            Label(model.isBroadcasting ? "Yayını Durdur" : "Yayını Başlat",
                  systemImage: model.isBroadcasting ? "stop.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isBroadcasting ? Color.red : Color.accentColor)
        .controlSize(.large)
        .disabled(!model.isBroadcasting && !model.canStart)
    }

    private var statistics: some View {
        let snapshot = model.snapshot
        let stats = model.senderStats
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(min(snapshot.peak, 1)))
                .progressViewStyle(.linear)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("Biçim").foregroundStyle(.secondary)
                    Text(snapshot.sampleRate > 0 ? "\(Int(snapshot.sampleRate)) Hz · 16-bit stereo" : "—")
                }
                GridRow {
                    Text("Gönderilen").foregroundStyle(.secondary)
                    Text("\(stats.packetsSent) paket · \(Self.megabytes(stats.bytesSent))")
                }
                if stats.sendErrors > 0 || snapshot.droppedFrames > 0 {
                    GridRow {
                        Text("Hata / kayıp").foregroundStyle(.secondary)
                        Text("\(stats.sendErrors) gönderim · \(snapshot.droppedFrames) kare")
                    }
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

enum StatusIcon {
    static func color(for level: IndicatorLevel) -> Color {
        Color(nsColor: nsColor(for: level))
    }

    static func nsColor(for level: IndicatorLevel) -> NSColor {
        switch level {
        case .active: return .systemGreen
        case .standby: return .systemGray
        case .error: return .systemRed
        }
    }

    /// Menü çubuğu simgesi: renkli durum noktası (şablon olmayan görüntü,
    /// böylece macOS onu tek renge çevirmez).
    static func image(for level: IndicatorLevel) -> NSImage {
        let color = nsColor(for: level)
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
