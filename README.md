# AirSpeaker — "iPad Ses Çıkışı" sanal ses cihazı

macOS için bir **CoreAudio HAL eklentisi (AudioServerPlugIn)**. Kurulduğunda
**Sistem Ayarları › Ses › Çıkış** listesinde ve menü çubuğundaki ses menüsünde
**iPad Ses Çıkışı** adında seçilebilir bir çıkış cihazı belirir.

| Aşama | Kapsam | Durum |
|---|---|---|
| 1 | Sanal cihazın sisteme kaydı, ses seviyesi/sessiz kontrolleri, örnekleme hızı seçimi | ✅ bu depo |
| 2 | Cihaza gelen sesin UDP üzerinden yayınlanması | ⏳ sonraki adım |

## Kext veya daemon gerekmiyor

- **Kext gerekmez.** Sanal ses cihazları için Apple'ın desteklediği yöntem,
  kullanıcı alanında çalışan AudioServerPlugIn'dir. Kext'ler kullanımdan
  kaldırıldı; Apple Silicon'da kurulmaları için güvenliğin düşürülmesi gerekir.
- **Ayrı bir daemon gerekmez.** Eklentiyi sistemin kendi ses daemon'u
  `coreaudiod` yükler. Kurulumda yapılan tek şey, `.driver` paketini
  `/Library/Audio/Plug-Ins/HAL/` altına kopyalamak ve `coreaudiod`'u yeniden
  başlatmaktır (`scripts/install.sh` bunu yapar).

## Gereksinimler

- macOS 12 Monterey veya üzeri (Apple Silicon ya da Intel; paket universal derlenir)
- Xcode Command Line Tools: `xcode-select --install`
- CMake 3.24+: `brew install cmake`
- VS Code ve önerilen eklentiler (klasör açılınca VS Code önerir):
  CMake Tools, clangd, CodeLLDB

## Proje yapısı

```
Driver/
  AirSpeakerDriver.cpp   HAL eklentisi (C++): nesne modeli, özellikler, saat, IO
  AirSpeakerConfig.h     Cihaz adı, UID, örnekleme hızı gibi ortak sabitler
  Info.plist.in          CFPlugIn kaydı (fabrika UUID → AirSpeaker_Create)
Tools/
  airspeaker-check.m     Objective-C doğrulama aracı (CoreAudio istemci API'si)
scripts/
  install.sh             Kur + coreaudiod'u yeniden başlat
  uninstall.sh           Kaldır
  restart-coreaudio.sh   coreaudiod'u yeniden başlat
  logs.sh                Sürücü günlüklerini canlı izle
.vscode/                 Görevler, hata ayıklama, clangd ayarları
.github/workflows/       macOS üzerinde derleme + kurulum + kayıt testi
```

## Derleme ve kurulum

### VS Code ile

1. Klasörü VS Code'da açın; önerilen eklentileri kurun.
2. **⇧⌘B** (`AirSpeaker: Derle`) — CMake yapılandırılır ve derlenir.
3. **⇧⌘P › Tasks: Run Task › AirSpeaker: Derle ve Kur (sudo)** — terminalde
   yönetici parolanız istenir.
4. **Tasks: Run Task › AirSpeaker: Cihazı doğrula** — tüm cihazlar listelenir,
   AirSpeaker `*` ile işaretlenir.

### Terminal ile

```bash
cmake --preset default
cmake --build --preset default
scripts/install.sh
build/airspeaker-check --list
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

Aşama 1'de cihaza çalınan ses yutulur; bu cihaz seçiliyken hoparlörden ses
gelmemesi beklenen davranıştır.

### Kaldırma

```bash
scripts/uninstall.sh
```

## Sorun giderme

| Belirti | Kontrol |
|---|---|
| Cihaz listede yok | `ls -l /Library/Audio/Plug-Ins/HAL/` — paket `root:wheel` sahipliğinde mi? |
| | `codesign --verify --strict /Library/Audio/Plug-Ins/HAL/AirSpeaker.driver` |
| | `scripts/logs.sh` açıkken `scripts/restart-coreaudio.sh` çalıştırın; "AirSpeaker HAL eklentisi yüklendi" satırı görünmeli |
| Değişiklikler yansımıyor | Her yeniden derlemeden sonra tekrar kurun; coreaudiod eski kopyayı bellekte tutar |
| Ses tamamen kesildi | `scripts/uninstall.sh` sürücüyü kaldırıp coreaudiod'u yeniden başlatır |

Eklentide hata ayıklamak için (SIP'nin hata ayıklama kısıtlaması kapalı olmalıdır):
`sudo lldb -n coreaudiod`.

## Mimari notlar

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
  olarak gelir.
- **Örnekleme hızı değişikliği:** `RequestDeviceConfigurationChange` ile
  host'tan istenir; host IO'yu durdurup `PerformDeviceConfigurationChange`'i çağırır.
- Cihaz UID'si (`AirSpeakerConfig.h`) sabit kalmalıdır; macOS varsayılan çıkış
  seçimini bu UID ile hatırlar.

## Aşama 2 yol haritası: UDP yayını

1. `DoIOOperation(WriteMix)` içinde gelen kareleri **kilitsiz bir halka tampona**
   kopyalamak. Bu kod gerçek zamanlı IO iş parçacığında çalışır; burada bellek
   ayırma, kilit bekleme veya ağ çağrısı yapılmamalıdır.
2. Ayrı bir gönderici iş parçacığı halka tampondan okuyup PCM paketlerini
   (sıra numarası + örnek zamanı başlığıyla) UDP üzerinden iPad'e gönderir.
3. `coreaudiod` eklentileri sandbox içinde çalıştırır. Ağ erişimi için iki seçenek
   var:
   - Eklentinin `Info.plist` dosyasına `AudioServerPlugIn_Network` (Boolean, `true`)
     anahtarını ekleyip UDP'yi doğrudan eklentiden göndermek (daha basit), veya
   - Sesi paylaşımlı bellek / XPC (`AudioServerPlugIn_MachServices`) ile ayrı bir
     yardımcı sürece aktarıp ağ işini orada yapmak (daha esnek; hedef IP gibi
     ayarlar için bir menü çubuğu uygulamasıyla birleştirilebilir).
