// swift-tools-version:5.9
//
// Kullanıcı oturumunda çalışan Swift bileşenleri. Sistem bileşenleri (HAL
// sürücüsü, broker daemon'u) CMake ile derlenir; bkz. CMakeLists.txt.

import PackageDescription

let package = Package(
    name: "AirSpeaker",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AirSpeaker", targets: ["AirSpeakerApp"]),
        .executable(name: "airspeaker-probe", targets: ["AirSpeakerProbe"]),
        .executable(name: "airspeaker-listen", targets: ["AirSpeakerListen"]),
        .library(name: "AirSpeakerKit", targets: ["AirSpeakerKit"]),
    ],
    targets: [
        // Sürücü ve broker ile paylaşılan IPC sözleşmesi ve halka tampon (C).
        .target(
            name: "CAirSpeakerIPC",
            path: "Shared",
            sources: ["AirSpeakerIPC.c"],
            publicHeadersPath: "include"
        ),
        // Broker'a XPC ile bağlanma, paylaşımlı belleği okuma.
        .target(
            name: "AirSpeakerKit",
            dependencies: ["CAirSpeakerIPC"],
            path: "App/Sources/AirSpeakerKit"
        ),
        // Menü çubuğu uygulaması.
        .executableTarget(
            name: "AirSpeakerApp",
            dependencies: ["AirSpeakerKit"],
            path: "App/Sources/AirSpeakerApp"
        ),
        // Komut satırından uçtan uca IPC (ve isteğe bağlı UDP) testi.
        .executableTarget(
            name: "AirSpeakerProbe",
            dependencies: ["AirSpeakerKit"],
            path: "App/Sources/AirSpeakerProbe"
        ),
        // UDP ses paketlerini dinleyen test alıcısı.
        .executableTarget(
            name: "AirSpeakerListen",
            dependencies: ["AirSpeakerKit"],
            path: "App/Sources/AirSpeakerListen"
        ),
        .testTarget(
            name: "AirSpeakerKitTests",
            dependencies: ["AirSpeakerKit"],
            path: "App/Tests/AirSpeakerKitTests"
        ),
    ]
)
