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
            Image(nsImage: StatusIcon.image(for: model.snapshot.status))
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = EngineSnapshot()

    private let engine = AirSpeakerEngine()

    init() {
        // Paketlenmeden (swift run) çalıştırıldığında da Dock simgesi göstermesin.
        NSApplication.shared.setActivationPolicy(.accessory)
        engine.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                if let self, self.snapshot != snapshot {
                    self.snapshot = snapshot
                }
            }
        }
        engine.start()
    }
}

struct StatusPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: StatusIcon.color(for: snapshot.status)))
                    .frame(width: 10, height: 10)
                Text("iPad Ses Çıkışı").font(.headline)
            }
            Text(StatusIcon.description(for: snapshot.status))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if snapshot.sampleRate > 0 {
                ProgressView(value: Double(min(snapshot.peak, 1)))
                    .progressViewStyle(.linear)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Örnekleme hızı").foregroundStyle(.secondary)
                        Text("\(Int(snapshot.sampleRate)) Hz")
                    }
                    GridRow {
                        Text("Alınan").foregroundStyle(.secondary)
                        Text(Self.duration(frames: snapshot.receivedFrames, sampleRate: snapshot.sampleRate))
                    }
                    GridRow {
                        Text("Kayıp kare").foregroundStyle(.secondary)
                        Text("\(snapshot.droppedFrames)")
                    }
                }
                .font(.caption.monospacedDigit())
            }

            Divider()
            Button("Çıkış") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 260)
    }

    private static func duration(frames: UInt64, sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "—" }
        let seconds = Double(frames) / sampleRate
        return String(format: "%.1f sn", seconds)
    }
}

enum StatusIcon {
    static func color(for status: LinkStatus) -> NSColor {
        switch status {
        case .streaming: return .systemGreen
        case .idle: return .systemYellow
        case .driverOffline, .brokerUnavailable: return .systemRed
        }
    }

    static func description(for status: LinkStatus) -> String {
        switch status {
        case .streaming: return "Ses alınıyor."
        case .idle: return "Sürücüye bağlı. Ses yok — çıkış olarak 'iPad Ses Çıkışı' seçili mi?"
        case .driverOffline: return "Broker çalışıyor ama sürücü kayıtlı değil (coreaudiod yeniden başlıyor olabilir)."
        case .brokerUnavailable(let reason): return reason
        }
    }

    /// Menü çubuğu simgesi: renkli durum noktası (şablon olmayan görüntü,
    /// böylece macOS onu tek renge çevirmez).
    static func image(for status: LinkStatus) -> NSImage {
        let color = color(for: status)
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
