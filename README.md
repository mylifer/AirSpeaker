# AirSpeaker — "iPad Ses Çıkışı" sanal ses cihazı

macOS için bir **CoreAudio HAL eklentisi (AudioServerPlugIn)**. Kurulduğunda
**Sistem Ayarları › Ses › Çıkış** listesinde ve menü çubuğundaki ses menüsünde
**iPad Ses Çıkışı** adında seçilebilir bir çıkış cihazı belirir.

| Aşama | Kapsam | Durum |
|---|---|---|
| 1 | Sanal cihazın sisteme kaydı, ses seviyesi/sessiz kontrolleri, örnekleme hızı seçimi | ✅ |
| 2 | Cihaza gelen sesin XPC + paylaşımlı bellek ile Swift menü çubuğu uygulamasına aktarılması | ✅ |
| 3 | UDP ile iPad'e yayın, menü çubuğu arayüzü (IP, port, başlat/durdur), DMG kurulum paketi | ✅ |
| 4 | iPad alıcısı (Swift Playgrounds, tek dosya): UDP alma, titreşim tamponu, çalma | ✅ |

## Hızlı kurulum (DMG)

1. GitHub'da **Actions › macOS** iş akışının son başarılı çalışmasını açın ve
   en alttaki **AirSpeaker-dmg** dosyasını indirin. Zip'i açınca
   `AirSpeaker-<sürüm>.dmg` çıkar.
2. Kurulum paketi Apple Developer ID ile imzalı ve Apple onaylı (notarize)
   olmadığı için macOS çift tıklamada "doğrulanamadı" deyip **Çöp Kutusuna
   Taşı** seçeneği sunar. Çöp kutusuna taşımayın; aşağıdaki iki yoldan birini
   kullanın.

   **En kolayı:** Terminal'de karantina işaretini kaldırın, sonra DMG'yi
   normal şekilde açın (`xattr -c ` yazıp DMG'yi Terminal penceresine
   sürükleyerek yolunu da ekleyebilirsiniz):

   ```bash
   xattr -c ~/Downloads/AirSpeaker-*.dmg
   open ~/Downloads/AirSpeaker-*.dmg
   ```

   **A) Terminal ile kurulum (uyarısız):** `installer` komutu Gatekeeper
   denetimine takılmaz.

   ```bash
   cd ~/Downloads
   hdiutil attach AirSpeaker-*.dmg
   sudo installer -pkg "/Volumes/AirSpeaker "*/"AirSpeaker Kurulum.pkg" -target /
   hdiutil detach "/Volumes/AirSpeaker "*
   ```

   **B) Sistem Ayarları ile:** DMG'yi açmayı deneyin, uyarıda **Bitti**'ye
   basın. **Sistem Ayarları › Gizlilik ve Güvenlik**'in en altında
   "AirSpeaker… engellendi" satırındaki **Yine de Aç**'a basıp parolanızı
   girin. DMG açılınca içindeki **AirSpeaker Kurulum.pkg** için de aynısını
   bir kez daha yapmanız gerekir.
3. Kurulum bitince menü çubuğunda (sağ üstte) gri bir nokta belirir.
4. **Sistem Ayarları › Ses › Çıkış**'tan **iPad Ses Çıkışı**'nı seçin.
5. Noktaya tıklayın, iPad'in IP adresini girin (port varsayılan 5000) ve
   **Yayını Başlat**'a basın.

| Gösterge | Anlamı |
|---|---|
| 🟢 Yeşil | Yayında (alt satırda "ses yok" yazıyorsa çıkış cihazı seçili değil veya çalan bir şey yok) |
| ⚪ Gri | Beklemede (yayın kapalı) veya bağlanıyor |
| 🔴 Kırmızı | Hata: hedefe ulaşılamıyor, hedef portu dinlemiyor, sürücü veya broker yok |

Kaldırmak için Terminal'de:

```bash
sudo "/Library/Application Support/AirSpeaker/uninstall.sh"
```

### iPad alıcısı (Swift Playgrounds)

1. iPad'de Swift Playgrounds'u açın ve **+** ile yeni bir **Uygulama** (App)
   oluşturun.
2. Soldaki dosya listesinde **MyApp** dosyasını açın, içindekileri silip
   [`iPad/AirSpeakerReceiver.swift`](iPad/AirSpeakerReceiver.swift)
   dosyasının tamamını yapıştırın. **ContentView** dosyası kullanılmaz;
   olduğu gibi kalabilir.
3. Uygulamayı çalıştırın (▶). Yerel ağ izni sorulursa izin verin. Ekranda
   iPad'in IP adresi görünür; bu adresi Mac'teki menüye girip yayını başlatın.

Alıcı, yaklaşık 21 ms ile başlayan ve çatlama olursa büyüyen, ağ sakinken
yeniden küçülen bir titreşim tamponu kullanır. Ekranda tampon, kayıp paket ve
çatlama sayıları görünür.

iPad olmadan test için aynı ağdaki başka bir Mac'te (ya da aynı Mac'te
`127.0.0.1` hedefiyle) test alıcısı: `swift run airspeaker-listen --port 5000`.

## Mimari

```
 Uygulamalar ──▶ coreaudiod ──▶ AirSpeaker.driver (HAL eklentisi, C++)
                                    │  IO iş parçacığı: WriteMix → halka tampona yaz
                                    │  (kilit yok, IPC yok, bellek ayırma yok)
                                    ▼
                  ┌──────── paylaşımlı bellek (xpc_shmem) ─────────┐
                  │  AirSpeakerRingHeader + 65536 kare Float32 PCM  │
                  └───────────────────────▲─────────────────────────┘
                                          │ okur (5 ms'de bir)
  XPC: driver-hello ──▶ airspeaker-broker ──▶ XPC: driver-state ──▶ AirSpeaker.app (Swift)
                        (LaunchDaemon)                              menü çubuğu
                                                                         │ UDPAudioSender
                                                                         ▼ (NWConnection)
                                                             UDP ──▶ iPad :5000
```

- **Kext gerekmez.** Sanal ses cihazları için Apple'ın desteklediği yöntem,
  kullanıcı alanında çalışan AudioServerPlugIn'dir. Eklentiyi sistemin ses
  daemon'u `coreaudiod` yükler.
- **Ses XPC mesajlarıyla taşınmaz.** Sürücü başlarken bir kez paylaşımlı bellek
  bölgesi oluşturur ve bunu XPC ile aktarır. Ses bundan sonra bu bölgedeki
  kilitsiz halka tampon üzerinden akar. Gerçek zamanlı ses iş parçacığı hiçbir
  zaman başka bir süreci beklemez; uygulama yavaşlarsa veya kapanırsa sürücü
  etkilenmez.
- **Broker neden gerekli?** HAL eklentisi `coreaudiod`'un sandbox'lı sürecinde,
  sistem bootstrap alanında çalışır. Yalnızca `Info.plist`'teki
  `AudioServerPlugIn_MachServices` listesinde adı geçen *sistem* Mach
  servislerine bağlanabilir; kullanıcı oturumundaki bir uygulamanın servislerini
  göremez. Bu yüzden küçük bir LaunchDaemon (`airspeaker-broker`, `nobody`
  kullanıcısıyla çalışır) sistem alanında `com.mylifer.airspeaker.broker`
  servisini yayınlar. Sürücü de uygulama da ona bağlanır. Broker ses verisine
  dokunmaz; yalnızca paylaşımlı bellek nesnesini iletir ve sürücü gelip
  gittikçe aboneleri bilgilendirir.
- **Yeniden bağlanma:** coreaudiod yeniden başlarsa sürücü yeni bir bölgeyle
  tekrar kaydolur ve broker uygulamaya yeni bölgeyi gönderir. Broker yeniden
  başlarsa hem sürücü hem uygulama otomatik olarak yeniden kaydolur.

IPC sözleşmesinin tamamı (servis adı, mesaj anahtarları, halka tampon
düzeni ve okuma/yazma fonksiyonları) tek bir C başlığındadır:
[`Shared/include/AirSpeakerIPC.h`](Shared/include/AirSpeakerIPC.h). Sürücü
(C++), broker (C) ve Swift uygulaması aynı başlığı kullanır.

## Gereksinimler

- macOS 12 Monterey veya üzeri (Apple Silicon ya da Intel; paket universal derlenir)
- Menü çubuğu uygulaması için macOS 13 Ventura veya üzeri
- Xcode Command Line Tools (Swift 5.9+ içerir): `xcode-select --install`
- CMake 3.24+: `brew install cmake`
- VS Code ve önerilen eklentiler (klasör açılınca VS Code önerir):
  CMake Tools, clangd, CodeLLDB, Swift

## Proje yapısı

```
Driver/
  AirSpeakerDriver.cpp   HAL eklentisi (C++): nesne modeli, özellikler, saat, IO, broker kaydı
  AirSpeakerConfig.h     Cihaz adı, UID, örnekleme hızı gibi ortak sabitler
  Info.plist.in          CFPlugIn kaydı + AudioServerPlugIn_MachServices
Shared/include/
  AirSpeakerIPC.h        IPC sözleşmesi + kilitsiz halka tampon (C; sürücü, broker ve Swift ortak)
Broker/
  main.c                 airspeaker-broker LaunchDaemon'u (C, XPC)
  com.mylifer.airspeaker.broker.plist   launchd tanımı
App/Sources/
  AirSpeakerKit/         Swift: broker istemcisi, halka tampon okuyucu, UDP paket biçimi, UDPAudioSender
  AirSpeakerApp/         Swift: menü çubuğu uygulaması (IP/port, başlat/durdur, durum göstergesi)
  AirSpeakerProbe/       Swift: komut satırından uçtan uca IPC (+ --udp) testi
  AirSpeakerListen/      Swift: UDP test alıcısı (airspeaker-listen)
App/Tests/               Swift birim testleri (paket biçimi, paketleyici)
iPad/
  AirSpeakerReceiver.swift  iPad alıcısı: Swift Playgrounds'a yapıştırılan tek dosya
Package.swift            Swift paketi
VERSION                  Sürüm numarası (CMake, uygulama ve kurulum paketi kullanır)
packaging/               pkg kurulum betikleri, karşılama sayfası, kaldırıcı, DMG "Beni Oku"
CMakeLists.txt           Sistem bileşenleri: sürücü, broker, airspeaker-check, testler
Tools/
  airspeaker-check.m     Objective-C doğrulama aracı (CoreAudio istemci API'si)
tests/
  ring_buffer_test.c     Halka tampon birim testleri (eşzamanlı yazar/okuyucu dahil)
scripts/
  install.sh             Sürücü + broker'ı kur, coreaudiod'u yeniden başlat
  uninstall.sh           Kaldır
  build-app.sh           Swift uygulamasını derle ve build/AirSpeaker.app olarak paketle (--universal)
  package.sh             build/AirSpeaker-<sürüm>.pkg ve .dmg üret
  restart-coreaudio.sh   coreaudiod'u yeniden başlat
  logs.sh                Sürücü + broker günlüklerini canlı izle
.vscode/                 Görevler, hata ayıklama, clangd ayarları
.github/workflows/       macOS: derleme, testler, kurulum, uçtan uca ses aktarım testi
```

## Kaynaktan derleme (geliştirme)

### VS Code ile

1. Klasörü VS Code'da açın; önerilen eklentileri kurun.
2. **⇧⌘B** (`AirSpeaker: Derle`): sürücü, broker ve araçlar derlenir.
3. **⇧⌘P › Tasks: Run Task › AirSpeaker: Sürücü + broker derle ve kur (sudo)**:
   terminalde yönetici parolanız istenir.
4. **Tasks: Run Task › AirSpeaker: Menü çubuğu uygulamasını çalıştır**: menü
   çubuğunda renkli bir nokta belirir.
5. Sistem Ayarları › Ses › Çıkış'ta "iPad Ses Çıkışı"nı seçin, menüde IP/port
   girip yayını başlatın.
6. Yayını test etmek için **Tasks: Run Task › AirSpeaker: UDP dinleyici (test,
   port 5000)** görevini çalıştırıp menüde hedef olarak `127.0.0.1` girin.

DMG'yi yerelde üretmek için: **Tasks: Run Task › AirSpeaker: Kurulum paketi
(DMG) oluştur** (çıktı: `build/AirSpeaker-<sürüm>.dmg`).

Uygulamada hata ayıklamak için Run and Debug panelinden
**AirSpeaker menü çubuğu uygulaması (LLDB)** yapılandırmasını kullanın.

### Terminal ile

```bash
# Sistem bileşenleri (sürücü + broker)
cmake --preset default
cmake --build --preset default
ctest --test-dir build          # halka tampon testleri
scripts/install.sh

# Menü çubuğu uygulaması
scripts/build-app.sh
open build/AirSpeaker.app

# Birim testleri
ctest --test-dir build && swift test

# Uygulamasız uçtan uca test (cihaza ses çalarken):
swift run airspeaker-listen --port 5000 &          # test alıcısı
swift run airspeaker-probe --seconds 10 --expect-audio --udp 127.0.0.1:5000

# Kurulum paketi + DMG
scripts/build-app.sh release --universal
scripts/package.sh
```

Derleme çıktısı `build/AirSpeaker.driver` paketidir. Paket ad-hoc olarak
imzalanır; bu, yerel kullanım için yeterlidir. Developer ID ile imzalamak için:
`cmake --preset default -DAIRSPEAKER_CODESIGN_IDENTITY="Developer ID Application: ..."`.

### Doğrulama

- **Sistem Ayarları › Ses › Çıkış**: "iPad Ses Çıkışı" listede olmalı ve seçilebilmeli.
- Menü çubuğundaki ses denetimi bu cihaz seçiliyken çalışmalı (ses seviyesi
  ve sessiz kontrolleri sürücüde tanımlıdır).
- **Audio MIDI Ayarları** uygulamasında 44.1 / 48 / 96 kHz arasından seçim yapılabilir.
- `build/airspeaker-check --set-default` cihazı varsayılan çıkış yapar.

Bu cihaz seçiliyken Mac'in hoparlöründen ses gelmemesi beklenen davranıştır;
ses yalnızca UDP ile yayınlanır.

### Kaldırma

```bash
scripts/uninstall.sh   # DMG ile kurulmuş olsa da çalışır
```

## Sorun giderme

| Belirti | Kontrol |
|---|---|
| "Hedef bu portu dinlemiyor" | iPad'de (veya test alıcısında) uygulama açık ve aynı port mu? |
| "Hedefe ulaşılamıyor" | Mac ve iPad aynı Wi-Fi ağında mı? IP doğru mu? (iPad: Ayarlar › Wi-Fi › ⓘ) |
| Menü çubuğunda kırmızı nokta, "broker'a ulaşılamıyor" | `sudo launchctl print system/com.mylifer.airspeaker.broker` — broker yüklü mü? `scripts/install.sh` tekrar çalıştırılabilir |
| Kırmızı nokta, "sürücü kayıtlı değil" | `scripts/logs.sh`: sürücü "airspeaker-broker'a kaydolundu" yazmalı; yazmıyorsa `scripts/restart-coreaudio.sh` |
| Cihaz listede yok | `ls -l /Library/Audio/Plug-Ins/HAL/` — paket `root:wheel` sahipliğinde mi? |
| | `codesign --verify --strict /Library/Audio/Plug-Ins/HAL/AirSpeaker.driver` |
| | `scripts/logs.sh` açıkken `scripts/restart-coreaudio.sh` çalıştırın; "AirSpeaker HAL eklentisi yüklendi" satırı görünmeli |
| Değişiklikler yansımıyor | Her yeniden derlemeden sonra tekrar kurun; coreaudiod eski kopyayı bellekte tutar |
| Ses tamamen kesildi | `scripts/uninstall.sh` sürücüyü kaldırıp coreaudiod'u yeniden başlatır |

Eklentide hata ayıklamak için (SIP'nin hata ayıklama kısıtlaması kapalı olmalıdır):
`sudo lldb -n coreaudiod`.

## Sürücü notları

**Nesne ağacı** (`Driver/AirSpeakerDriver.cpp`):

```
PlugIn (ID 1)
 └─ Device  "iPad Ses Çıkışı"     UID: AirSpeaker_iPadOutput_UID
     ├─ Stream (ID 3)             çıkış, 2 kanal, Float32 interleaved
     ├─ Volume control (ID 4)     -96 dB … 0 dB
     └─ Mute control (ID 5)
```

- **Kayıt:** `Info.plist`, paketi `kAudioServerPlugInTypeUUID` türünde bir
  CFPlugIn olarak tanımlar. `coreaudiod` paketi yükler, `AirSpeaker_Create`
  fabrika fonksiyonunu çağırır ve dönen `AudioServerPlugInDriverInterface`
  tablosu üzerinden cihazın özelliklerini sorgular.
- **Saat:** Gerçek bir donanım saati olmadığından `GetZeroTimeStamp`,
  `mach_absolute_time` tabanlı bir saat üretir (her 16384 örnekte bir zaman damgası).
- **IO:** `WillDoIOOperation` yalnızca `WriteMix` işlemini kabul eder. Sistemin
  karıştırdığı çıkış sesi `DoIOOperation` içinde interleaved Float32 stereo
  olarak gelir. Ses seviyesi (genlik = skaler³) ve sessiz ayarı uygulanarak
  halka tampona yazılır.
- **Örnekleme hızı değişikliği:** `RequestDeviceConfigurationChange` ile
  host'tan istenir; host IO'yu durdurup `PerformDeviceConfigurationChange`'i çağırır.
- Cihaz UID'si (`AirSpeakerConfig.h`) sabit kalmalıdır; macOS varsayılan çıkış
  seçimini bu UID ile hatırlar.

## Halka tampon

- Tek yazar (sürücünün IO iş parçacığı), istenen sayıda bağımsız okuyucu.
  Her okuyucu kendi konumunu kendi belleğinde tutar.
- Yazar hiçbir zaman beklemez. Okuyucu ~1 saniyeden fazla geride kalırsa en
  eski geçerli veriye atlar ve atlanan kareler "kayıp kare" olarak sayılır.
- Okuyucu, kopyalama sırasında yazarın o bölgeye ulaşıp ulaşmadığını kopyadan
  sonra kontrol eder; yarım yazılmış veri asla kabul edilmez.
- `writeFrame` sayacı hiç geri sarmaz. Örnekleme hızı başlıkta tutulur ve
  okuyucu her okumada bunu görür.

## Güvenlik notları

- Broker yalnızca `_coreaudiod` veya root kullanıcısıyla çalışan süreçlerden
  sürücü kaydı kabul eder; başka bir süreç sahte ses kaynağı olamaz.
- Şu an Mac'teki herhangi bir yerel kullanıcı broker'a abone olup bu cihaza
  çalınan sesi okuyabilir. Uygulama bir Developer ID ile imzalandığında
  aboneler `xpc_connection_set_peer_code_signing_requirement` ile yalnızca bu
  uygulamayla sınırlandırılabilir.

## UDP paket biçimi

Her paket 28 baytlık bir başlık ve ardından 16-bit PCM'den oluşur. Tüm sayılar
little-endian'dır. Tanım ve testler: `App/Sources/AirSpeakerKit/AudioPacket.swift`.

| Bayt | Alan | Tür | Açıklama |
|---|---|---|---|
| 0 | magic | 4 bayt | `ASPK` |
| 4 | version | UInt8 | 1 |
| 5 | format | UInt8 | 1 = PCM signed 16-bit, interleaved |
| 6 | channelCount | UInt8 | 2 |
| 7 | — | UInt8 | 0 |
| 8 | sampleRate | UInt32 | Hz (ör. 48000) |
| 12 | sequence | UInt32 | her pakette +1; kayıp/sıra dışı paket tespiti |
| 16 | frameIndex | UInt64 | paketin ilk karesinin akıştaki konumu |
| 24 | frameCount | UInt16 | paketteki kare sayısı (normalde 256) |
| 26 | — | UInt16 | 0 |
| 28 | PCM | | `frameCount × channelCount × 2` bayt (L, R, L, R, …) |

- 256 kare/paket: 48 kHz'de 5,3 ms ses, 1052 baytlık paket (MTU altında,
  parçalanma yok), ~188 paket/sn, ~1,6 Mbit/s.
- Gönderici `serviceClass = .interactiveVoice` kullanır (Wi-Fi'de WMM ses
  kuyruğu). Ağ yolu hazır değilken gelen ses atılır, biriktirilmez.
- Örnekleme hızı değişirse (Audio MIDI Ayarları) yarım paket eski hızla
  gönderilir, sonraki paketler yeni hızı taşır.
- Alıcı, kayıp paketleri `sequence` boşluklarından, zamanlamayı `frameIndex`'ten
  çıkarabilir. Örnek uygulama: `App/Sources/AirSpeakerListen/main.swift`.
