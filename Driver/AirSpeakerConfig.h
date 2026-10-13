// AirSpeakerConfig.h
//
// Sürücü (C++) ve yardımcı araçlar (Objective-C) arasında paylaşılan sabitler.
// Bu başlık hem C/C++ hem de Objective-C tarafından derlendiği için yalnızca
// önişlemci makroları içerir.

#ifndef AIRSPEAKER_CONFIG_H
#define AIRSPEAKER_CONFIG_H

// Sistem Ayarları > Ses menüsünde görünen cihaz adı (UTF-8).
#define AIRSPEAKER_DEVICE_NAME "iPad Ses Çıkışı"

// Üretici adı (Audio MIDI Ayarları'nda görünür).
#define AIRSPEAKER_MANUFACTURER "AirSpeaker"

// Cihazın kalıcı kimliği. macOS varsayılan çıkış seçimini bu UID ile hatırlar;
// değiştirilirse sistem cihazı yeni bir cihaz olarak görür.
#define AIRSPEAKER_DEVICE_UID "AirSpeaker_iPadOutput_UID"
#define AIRSPEAKER_MODEL_UID "AirSpeaker_iPadOutput_Model"

// os_log alt sistemi: `log stream --predicate 'subsystem == "com.mylifer.airspeaker"'`
#define AIRSPEAKER_LOG_SUBSYSTEM "com.mylifer.airspeaker"

// Cihaz ilk yüklendiğinde kullanılan örnekleme hızı (Hz).
#define AIRSPEAKER_DEFAULT_SAMPLE_RATE 48000.0

#endif  // AIRSPEAKER_CONFIG_H
