// airspeaker-probe
//
// Sürücü → broker → uygulama IPC yolunu komut satırından doğrular: broker'a
// abone olur, paylaşımlı halka tamponu okur ve özet yazdırır.
//
//   airspeaker-probe [--seconds N] [--expect-audio] [--udp HOST:PORT]
//
// --udp verilirse alınan ses UDPAudioSender ile HOST:PORT'a da yayınlanır
// (menü çubuğu uygulamasıyla aynı yol); karşı tarafta airspeaker-listen
// çalıştırılarak doğrulanabilir.
//
// Çıkış kodu: 0 = başarılı, 1 = sürücüye bağlanılamadı,
//             2 = --expect-audio verildi ama ses (sıfır olmayan örnek) gelmedi.

import AirSpeakerKit
import Foundation

var seconds = 5.0
var expectAudio = false
var udpTarget: (host: String, port: UInt16)?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--seconds":
        seconds = arguments.next().flatMap(Double.init) ?? seconds
    case "--expect-audio":
        expectAudio = true
    case "--udp":
        let parts = (arguments.next() ?? "").split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            print("--udp HOST:PORT biçiminde olmalı")
            exit(64)
        }
        udpTarget = (String(parts[0]), port)
    default:
        print("Kullanım: airspeaker-probe [--seconds N] [--expect-audio] [--udp HOST:PORT]")
        exit(argument == "--help" ? 0 : 64)
    }
}

func describe(_ status: LinkStatus) -> String {
    switch status {
    case .streaming: return "ses akıyor"
    case .idle: return "bağlı, ses yok"
    case .driverOffline: return "sürücü çevrimdışı"
    case .brokerUnavailable(let reason): return "broker yok: \(reason)"
    }
}

let engine = AirSpeakerEngine()
var maxPeak: Float = 0
var everConnected = false
var lastLine = ""

engine.onSnapshot = { snapshot in
    maxPeak = max(maxPeak, snapshot.peak)
    if snapshot.status == .idle || snapshot.status == .streaming {
        everConnected = true
    }
    let line = "[\(describe(snapshot.status))] \(Int(snapshot.sampleRate)) Hz, "
        + "\(snapshot.receivedFrames) kare, \(snapshot.droppedFrames) kayıp, tepe \(String(format: "%.4f", snapshot.peak))"
    if line != lastLine {
        print(line)
        lastLine = line
    }
}
engine.start()

let sender = UDPAudioSender()
if let udpTarget {
    sender.onStateChange = { state in print("UDP \(udpTarget.host):\(udpTarget.port): \(state)") }
    sender.start(host: udpTarget.host, port: udpTarget.port)
    engine.setSink(sender)
}

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    let snapshot = engine.currentSnapshot()
    maxPeak = max(maxPeak, snapshot.peak)
    print("")
    print("Özet: durum=\(describe(snapshot.status)), alınan=\(snapshot.receivedFrames) kare, "
        + "kayıp=\(snapshot.droppedFrames) kare, en yüksek tepe=\(String(format: "%.4f", maxPeak))")

    guard everConnected || snapshot.status == .idle || snapshot.status == .streaming else {
        print("✗ Sürücünün paylaşımlı belleğine bağlanılamadı.")
        exit(1)
    }
    if expectAudio && (snapshot.receivedFrames == 0 || maxPeak < 0.0001) {
        print("✗ Ses bekleniyordu ama gelmedi.")
        exit(2)
    }
    if udpTarget != nil {
        let stats = sender.currentStats()
        print("UDP: \(stats.packetsSent) paket, \(stats.bytesSent) bayt gönderildi, \(stats.sendErrors) hata"
            + (stats.lastError.map { " (son: \($0))" } ?? ""))
        if expectAudio && stats.packetsSent == 0 {
            print("✗ UDP üzerinden hiç paket gönderilmedi.")
            exit(2)
        }
    }
    print("✓ Sürücü → broker → uygulama IPC yolu çalışıyor.")
    exit(0)
}

dispatchMain()
