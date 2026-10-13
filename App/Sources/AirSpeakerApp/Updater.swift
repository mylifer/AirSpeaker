import AirSpeakerKit
import CryptoKit
import Foundation

/// GitHub Releases üzerinden otomatik güncelleme.
///
/// Açılışta ve 6 saatte bir en son sürümü denetler. Daha yeni bir sürüm varsa
/// kurulum paketini (.pkg) arka planda indirir ve aynı sürümdeki .sha256
/// dosyasıyla doğrular. Kurulum, sürücü sistem klasörlerine yazıldığı için
/// macOS'un yönetici parolası penceresiyle başlatılır; paketin kurulum betiği
/// eski uygulamayı kapatıp yenisini açar.
///
/// Uygulamanın kendi indirdiği dosyalara karantina işareti konmadığı ve
/// `installer` Gatekeeper denetimi yapmadığı için "doğrulanamadı" uyarısı çıkmaz.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case disabled               // paketlenmemiş geliştirme sürümü
        case idle
        case checking
        case upToDate
        case downloading(version: String)
        case ready(version: String, package: URL)
        case installing(version: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    let currentVersion: AppVersion?

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/mylifer/AirSpeaker/releases/latest")!
    private let checkInterval: TimeInterval = 6 * 60 * 60
    private var timer: Timer?

    init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        currentVersion = version.flatMap(AppVersion.init)
        guard currentVersion != nil else {
            state = .disabled
            return
        }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func check() async {
        guard let currentVersion else { return }
        switch state {
        case .disabled, .checking, .downloading, .ready, .installing:
            return
        case .idle, .upToDate, .failed:
            break
        }
        state = .checking
        do {
            var request = URLRequest(url: latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                // Henüz yayınlanmış sürüm yok.
                state = .upToDate
                return
            }
            guard status == 200 else { throw UpdateError.http(status) }

            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let latest = AppVersion(release.tagName), latest > currentVersion else {
                state = .upToDate
                return
            }
            guard let package = release.assets.first(where: { $0.name == "AirSpeaker-\(latest).pkg" }),
                  let checksum = release.assets.first(where: { $0.name == package.name + ".sha256" })
            else { throw UpdateError.missingAsset }

            state = .downloading(version: latest.description)
            let file = try await download(package, checksum: checksum)
            state = .ready(version: latest.description, package: file)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// Yönetici parolası sorarak kurulumu başlatır. Başarılı olursa kurulum
    /// betiği bu uygulamayı kapatıp yeni sürümü açar.
    func install() {
        guard case .ready(let version, let package) = state else { return }
        state = .installing(version: version)

        let command = "/usr/sbin/installer -pkg \(Self.shellQuoted(package.path)) -target /"
        let script = "do shell script \(Self.appleScriptQuoted(command)) with administrator privileges"
        // Ayrı bir süreç: kurulum betiği bu uygulamayı kapattığında kurulum sürer.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.terminationHandler = { [weak self] finished in
            let succeeded = finished.terminationStatus == 0
            Task { @MainActor in
                guard let self else { return }
                // İptal edildiyse (parola penceresi kapatıldı) yeniden yüklenebilir kalsın.
                self.state = succeeded ? .upToDate : .ready(version: version, package: package)
            }
        }
        do {
            try process.run()
        } catch {
            state = .failed("Kurulum başlatılamadı: \(error.localizedDescription)")
        }
    }

    // MARK: - Özel

    private func download(_ package: Release.Asset, checksum: Release.Asset) async throws -> URL {
        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: checksum.browserDownloadURL)
        try Self.requireOK(checksumResponse)
        guard let expected = String(decoding: checksumData, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first?.lowercased(), expected.count == 64
        else { throw UpdateError.badChecksumFile }

        let (temporary, response) = try await URLSession.shared.download(from: package.browserDownloadURL)
        try Self.requireOK(response)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirSpeakerUpdate", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(package.name)
        try FileManager.default.moveItem(at: temporary, to: destination)

        let data = try Data(contentsOf: destination, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateError.checksumMismatch
        }
        return destination
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private enum UpdateError: Error {
        case http(Int)
        case missingAsset
        case badChecksumFile
        case checksumMismatch
    }

    private static func requireOK(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UpdateError.http(let status):
            return "Sunucu yanıtı: HTTP \(status)"
        case UpdateError.missingAsset:
            return "Yeni sürümde kurulum paketi bulunamadı"
        case UpdateError.badChecksumFile, UpdateError.checksumMismatch:
            return "İndirilen paket doğrulanamadı"
        default:
            return error.localizedDescription
        }
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
