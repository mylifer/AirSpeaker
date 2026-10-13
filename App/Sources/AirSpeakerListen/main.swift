// airspeaker-listen
//
// AirSpeaker UDP ses paketlerini dinleyen test alıcısı. iPad uygulaması
// yazılmadan önce yayını Mac'te (veya başka bir Mac'te) doğrulamak için.
//
//   airspeaker-listen [--port 5000] [--seconds N] [--expect-audio]
//
// --seconds verilmezse Ctrl+C'ye kadar çalışır. Çıkış kodu: 0 = başarılı,
// 2 = --expect-audio verildi ama ses (sıfır olmayan örnek) gelmedi.

import AirSpeakerKit
import Foundation
import Network

var port: UInt16 = 5000
var seconds: Double?
var expectAudio = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--port":
        port = arguments.next().flatMap { UInt16($0) } ?? port
    case "--seconds":
        seconds = arguments.next().flatMap(Double.init)
    case "--expect-audio":
        expectAudio = true
    default:
        print("Kullanım: airspeaker-listen [--port 5000] [--seconds N] [--expect-audio]")
        exit(argument == "--help" ? 0 : 64)
    }
}

struct ReceiveStats {
    var packets: UInt64 = 0
    var invalidPackets: UInt64 = 0
    var frames: UInt64 = 0
    var lostPackets: UInt64 = 0
    var reorderedPackets: UInt64 = 0
    var expectedSequence: UInt32?
    var sampleRate: UInt32 = 0
    var channels: UInt8 = 0
    var intervalPeak: Int16 = 0
    var maxPeak: Int16 = 0

    mutating func handle(_ packet: Data) {
        guard let header = AudioPacketHeader.decode(packet) else {
            invalidPackets += 1
            return
        }
        packets += 1
        frames += UInt64(header.frameCount)
        sampleRate = header.sampleRate
        channels = header.channelCount
        if let expected = expectedSequence {
            let gap = header.sequence &- expected
            if gap < UInt32.max / 2 {
                lostPackets += UInt64(gap)
                expectedSequence = header.sequence &+ 1
            } else {
                // Çok büyük "boşluk" aslında geriden gelen (sırası bozulmuş) pakettir.
                reorderedPackets += 1
            }
        } else {
            expectedSequence = header.sequence &+ 1
        }
        for sample in header.samples(in: packet) {
            let magnitude = sample == Int16.min ? Int16.max : abs(sample)
            intervalPeak = max(intervalPeak, magnitude)
        }
        maxPeak = max(maxPeak, intervalPeak)
    }
}

var stats = ReceiveStats()

guard let endpointPort = NWEndpoint.Port(rawValue: port),
      let listener = try? NWListener(using: .udp, on: endpointPort)
else {
    print("✗ UDP \(port) portu açılamadı.")
    exit(1)
}

func receive(on connection: NWConnection) {
    connection.receiveMessage { data, _, _, error in
        if let data {
            stats.handle(data)
        }
        if error == nil {
            receive(on: connection)
        }
    }
}

listener.newConnectionHandler = { connection in
    print("Gönderici: \(connection.endpoint)")
    connection.start(queue: .main)
    receive(on: connection)
}
listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        print("UDP \(port) dinleniyor…")
    case .failed(let error):
        print("✗ Dinleyici hatası: \(error)")
        exit(1)
    default:
        break
    }
}
listener.start(queue: .main)

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    if stats.packets > 0 {
        let peak = Double(stats.intervalPeak) / Double(Int16.max)
        print("\(stats.packets) paket, \(stats.frames) kare, \(stats.sampleRate) Hz × \(stats.channels) kanal, "
            + "kayıp \(stats.lostPackets), sıra dışı \(stats.reorderedPackets), tepe \(String(format: "%.4f", peak))")
    }
    stats.intervalPeak = 0
}
timer.resume()

if let seconds {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        let peak = Double(stats.maxPeak) / Double(Int16.max)
        print("")
        print("Özet: \(stats.packets) paket, \(stats.frames) kare, kayıp \(stats.lostPackets) paket, "
            + "geçersiz \(stats.invalidPackets), en yüksek tepe \(String(format: "%.4f", peak))")
        if expectAudio && (stats.packets == 0 || peak < 0.0001) {
            print("✗ UDP üzerinden ses bekleniyordu ama gelmedi.")
            exit(2)
        }
        print("✓ UDP ses alımı çalışıyor.")
        exit(0)
    }
}

dispatchMain()
