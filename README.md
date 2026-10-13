# AirSpeaker — "iPad Ses Çıkışı" sanal ses cihazı

macOS için bir **CoreAudio HAL eklentisi (AudioServerPlugIn)**. Kurulduğunda
**Sistem Ayarları › Ses › Çıkış** listesinde ve menü çubuğundaki ses menüsünde
**iPad Ses Çıkışı** adında seçilebilir bir çıkış cihazı belirir.

| Aşama | Kapsam | Durum |
|---|---|---|
| 1 | Sanal cihazın sisteme kaydı, ses seviyesi/sessiz kontrolleri, örnekleme hızı seçimi | ✅ |
| 2 | Cihaza gelen sesin XPC + paylaşımlı bellek ile Swift menü çubuğu uygulamasına aktarılması | ✅ |
| 3 | Swift uygulamasından UDP ile hedef IP'ye yayın, IP ayarları | ⏳ sonraki adım |

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
                        (LaunchDaemon)                              menü çubuğu, AudioSink
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
  AirSpeakerKit/         Swift: broker istemcisi, halka tampon okuyucu, AudioSink protokolü
  AirSpeakerApp/         Swift: menü çubuğu uygulaması (yeşil/sarı/kırmızı gösterge)
  AirSpeakerProbe/       Swift: komut satırından uçtan uca IPC testi
Package.swift            Swift paketi (uygulama, probe, AirSpeakerKit)
CMakeLists.txt           Sistem bileşenleri: sürücü, broker, airspeaker-check, testler
Tools/
  airspeaker-check.m     Objective-C doğrulama aracı (CoreAudio istemci API'si)
tests/
  ring_buffer_test.c     Halka tampon birim testleri (eşzamanlı yazar/okuyucu dahil)
scripts/
  install.sh             Sürücü + broker'ı kur, coreaudiod'u yeniden başlat
  uninstall.sh           Kaldır
  build-app.sh           Swift uygulamasını derle ve build/AirSpeaker.app olarak paketle
  restart-coreaudio.sh   coreaudiod'u yeniden başlat
  logs.sh                Sürücü + broker günlüklerini canlı izle
.vscode/                 Görevler, hata ayıklama, clangd ayarları
.github/workflows/       macOS: derleme, testler, kurulum, uçtan uca ses aktarım testi
```

## Derleme ve kurulum

### VS Code ile

1. Klasörü VS Code'da açın; önerilen eklentileri kurun.
2. **⇧⌘B** (`AirSpeaker: Derle`): sürücü, broker ve araçlar derlenir.
3. **⇧⌘P › Tasks: Run Task › AirSpeaker: Sürücü + broker derle ve kur (sudo)**:
   terminalde yönetici parolanız istenir.
4. **Tasks: Run Task › AirSpeaker: Menü çubuğu uygulamasını çalıştır**: menü
   çubuğunda renkli bir nokta belirir.
5. Sistem Ayarları › Ses › Çıkış'ta "iPad Ses Çıkışı"nı seçip bir şey çalın:
   nokta yeşile döner, paneldeki seviye göstergesi hareket eder.

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

# IPC'yi uygulamasız doğrulamak için (cihaza ses çalarken):
swift run airspeaker-probe --seconds 10 --expect-audio
```

### Menü çubuğu göstergesi

| Renk | Anlamı |
|---|---|
| 🟢 Yeşil | Sürücüye bağlı, ses akıyor |
| 🟡 Sarı | Sürücüye bağlı, ses yok (cihaz seçili değil veya çalan bir şey yok) |
| 🔴 Kırmızı | Broker'a ulaşılamıyor ya da sürücü kayıtlı değil |

Derleme çıktısı `build/AirSpeaker.driver` paketidir. Paket ad-hoc olarak
imzalanır; bu, yerel kullanım için yeterlidir. Developer ID ile imzalamak için:
`cmake --preset default -DAIRSPEAKER_CODESIGN_IDENTITY="Developer ID Application: ..."`.

### Doğrulama

- **Sistem Ayarları › Ses › Çıkış**: "iPad Ses Çıkışı" listede olmalı ve seçilebilmeli.
- Menü çubuğundaki ses denetimi bu cihaz seçiliyken çalışmalı (ses seviyesi
  ve sessiz kontrolleri sürücüde tanımlıdır).
- **Audio MIDI Ayarları** uygulamasında 44.1 / 48 / 96 kHz arasından seçim yapılabilir.
- `build/airspeaker-check --set-default` cihazı varsayılan çıkış yapar.

Ses henüz ağa gönderilmiyor (Aşama 3). Bu cihaz seçiliyken hoparlörden ses
gelmemesi beklenen davranıştır.

### Kaldırma

```bash
scripts/uninstall.sh
```

## Sorun giderme

| Belirti | Kontrol |
|---|---|
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

## Aşama 3 yol haritası: UDP yayını

1. `AirSpeakerKit` içinde `AudioSink` protokolünü uygulayan bir `UDPSender`
   (Network.framework, `NWConnection` UDP). `AirSpeakerEngine.setSink(_:)` ile
   bağlanır; ses zaten motorun kuyruğunda 5 ms'lik parçalar halinde gelir.
2. Paket biçimi: sıra numarası + kare konumu + örnekleme hızı başlığı ve PCM
   (gerekirse Int16'ya dönüştürülmüş) yük. Paket başına MTU'ya sığan kare sayısı.
3. Menü çubuğu paneline hedef IP/port alanı (UserDefaults'ta saklanır) ve
   gönderim durumu.
