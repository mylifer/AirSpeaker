// AirSpeakerIPC.h
//
// Sürücü (C++), broker daemon'u (C) ve menü çubuğu uygulaması (Swift)
// arasında paylaşılan IPC sözleşmesi.
//
// Veri yolu:
//
//   coreaudiod ─ AirSpeaker.driver ──(XPC: driver-hello + shmem)──▶ airspeaker-broker
//                     │                                                  │
//                     │ halka tampona yazar              (XPC: driver-state + shmem)
//                     ▼                                                  ▼
//            [ paylaşımlı bellek: AirSpeakerRingHeader + PCM ] ◀── okur ── AirSpeaker.app
//
// Ses verisi XPC mesajlarıyla taşınmaz. Sürücü bir kez paylaşımlı bellek
// bölgesi oluşturur ve bunu XPC ile broker'a verir; broker aynı bölgeyi
// abone olan uygulamalara iletir. Bundan sonra ses, kilitsiz tek
// yazar / çok okuyucu halka tampon üzerinden akar; gerçek zamanlı IO iş
// parçacığında hiçbir IPC çağrısı yapılmaz.
//
// Bu başlık yalnızca C99 + Clang/GCC __atomic yerleşiklerini kullanır; C, C++,
// Objective-C ve (Clang modülü olarak) Swift tarafından derlenebilir.

#ifndef AIRSPEAKER_IPC_H
#define AIRSPEAKER_IPC_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - XPC sözleşmesi

// Broker'ın sistem (privileged) bootstrap alanında yayınladığı Mach servisi.
// Driver/Info.plist.in (AudioServerPlugIn_MachServices) ve
// Broker/com.mylifer.airspeaker.broker.plist ile aynı olmalıdır.
#define AIRSPEAKER_BROKER_SERVICE "com.mylifer.airspeaker.broker"

#define AIRSPEAKER_IPC_PROTOCOL_VERSION 1

// Mesaj anahtarları
#define AIRSPEAKER_MSG_KEY_TYPE "type"
#define AIRSPEAKER_MSG_KEY_VERSION "version"
#define AIRSPEAKER_MSG_KEY_SHMEM "shmem"
#define AIRSPEAKER_MSG_KEY_DRIVER_ONLINE "driverOnline"
#define AIRSPEAKER_MSG_KEY_STATUS "status"

// Mesaj türleri
#define AIRSPEAKER_MSG_DRIVER_HELLO "driver-hello"  // sürücü -> broker (yanıtlı)
#define AIRSPEAKER_MSG_SUBSCRIBE "subscribe"        // uygulama -> broker
#define AIRSPEAKER_MSG_DRIVER_STATE "driver-state"  // broker -> uygulama (durum her değiştiğinde)

// MARK: - Paylaşımlı halka tampon

#define AIRSPEAKER_RING_MAGIC 0x41535247u  // 'ASRG'
#define AIRSPEAKER_RING_VERSION 1u
#define AIRSPEAKER_RING_CHANNELS 2u
// 2'nin kuvveti; 48 kHz'de ~1,36 sn ses.
#define AIRSPEAKER_RING_CAPACITY_FRAMES 65536u
// Yazar, tek seferde en fazla bu kadar kare yazıp yazma konumunu yayınlar.
#define AIRSPEAKER_RING_MAX_WRITE_FRAMES 4096u
// Okuyucu, yazarın en fazla (kapasite - güvenlik payı) kare gerisindeki
// verileri geçerli sayar. Pay, yazarın henüz yayınlamadığı (yazılmakta olan)
// kareleri kapsar; böylece yarım yazılmış veri asla kabul edilmez.
#define AIRSPEAKER_RING_SAFETY_FRAMES 16384u
// Başlık bir sayfa kaplar; PCM verisi sayfa hizalı başlar.
#define AIRSPEAKER_RING_HEADER_BYTES 4096u

// Paylaşımlı bölgenin başındaki başlık. Örnekler interleaved Float32'dir
// (L, R, L, R, ...) ve başlıktan AIRSPEAKER_RING_HEADER_BYTES sonra başlar.
typedef struct AirSpeakerRingHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t channels;
    uint32_t capacityFrames;
    uint32_t sampleRate;  // atomik; Hz
    uint32_t reserved;
    uint64_t writeFrame;  // atomik; bugüne kadar yazılan toplam kare (hiç geri sarmaz)
} AirSpeakerRingHeader;

static inline size_t airspeaker_ring_region_size(void) {
    return (size_t)AIRSPEAKER_RING_HEADER_BYTES +
           (size_t)AIRSPEAKER_RING_CAPACITY_FRAMES * AIRSPEAKER_RING_CHANNELS * sizeof(float);
}

static inline float* airspeaker_ring_samples(AirSpeakerRingHeader* header) {
    return (float*)((uint8_t*)header + AIRSPEAKER_RING_HEADER_BYTES);
}

static inline const float* airspeaker_ring_samples_const(const AirSpeakerRingHeader* header) {
    return (const float*)((const uint8_t*)header + AIRSPEAKER_RING_HEADER_BYTES);
}

// Yeni ayrılmış (sıfırlanmış olması gerekmeyen) bölgeyi hazırlar. En az
// airspeaker_ring_region_size() bayt olmalıdır.
static inline AirSpeakerRingHeader* airspeaker_ring_init(void* region, uint32_t sampleRate) {
    AirSpeakerRingHeader* header = (AirSpeakerRingHeader*)region;
    memset(region, 0, airspeaker_ring_region_size());
    header->magic = AIRSPEAKER_RING_MAGIC;
    header->version = AIRSPEAKER_RING_VERSION;
    header->channels = AIRSPEAKER_RING_CHANNELS;
    header->capacityFrames = AIRSPEAKER_RING_CAPACITY_FRAMES;
    __atomic_store_n(&header->sampleRate, sampleRate, __ATOMIC_RELAXED);
    __atomic_store_n(&header->writeFrame, (uint64_t)0, __ATOMIC_RELEASE);
    return header;
}

// Başka bir süreçten eşlenen bölgeyi doğrular; geçersizse NULL döner.
static inline const AirSpeakerRingHeader* airspeaker_ring_validate(const void* region, size_t size) {
    if (region == NULL || size < airspeaker_ring_region_size()) {
        return NULL;
    }
    const AirSpeakerRingHeader* header = (const AirSpeakerRingHeader*)region;
    if (header->magic != AIRSPEAKER_RING_MAGIC || header->version != AIRSPEAKER_RING_VERSION ||
        header->channels != AIRSPEAKER_RING_CHANNELS || header->capacityFrames != AIRSPEAKER_RING_CAPACITY_FRAMES) {
        return NULL;
    }
    return header;
}

static inline void airspeaker_ring_set_sample_rate(AirSpeakerRingHeader* header, uint32_t sampleRate) {
    __atomic_store_n(&header->sampleRate, sampleRate, __ATOMIC_RELAXED);
}

static inline uint32_t airspeaker_ring_sample_rate(const AirSpeakerRingHeader* header) {
    return __atomic_load_n(&header->sampleRate, __ATOMIC_RELAXED);
}

static inline uint64_t airspeaker_ring_write_frame(const AirSpeakerRingHeader* header) {
    return __atomic_load_n(&header->writeFrame, __ATOMIC_ACQUIRE);
}

// Yazar (sürücünün gerçek zamanlı IO iş parçacığı). Bellek ayırmaz, kilit
// almaz, beklemez. Okuyucuların durumundan bağımsızdır: kimse okumuyorsa en
// eski veri sessizce üzerine yazılır.
static inline void airspeaker_ring_write(AirSpeakerRingHeader* header, const float* source, uint32_t frameCount,
                                         float gain) {
    float* samples = airspeaker_ring_samples(header);
    const uint32_t capacity = AIRSPEAKER_RING_CAPACITY_FRAMES;
    const uint32_t channels = AIRSPEAKER_RING_CHANNELS;
    uint64_t writeFrame = __atomic_load_n(&header->writeFrame, __ATOMIC_RELAXED);

    while (frameCount > 0) {
        const uint32_t chunk =
            frameCount < AIRSPEAKER_RING_MAX_WRITE_FRAMES ? frameCount : AIRSPEAKER_RING_MAX_WRITE_FRAMES;
        uint32_t done = 0;
        while (done < chunk) {
            const uint32_t index = (uint32_t)((writeFrame + done) % capacity);
            const uint32_t span = (chunk - done) < (capacity - index) ? (chunk - done) : (capacity - index);
            float* destination = samples + (size_t)index * channels;
            const float* from = source + (size_t)done * channels;
            const size_t count = (size_t)span * channels;
            if (gain == 1.0f) {
                memcpy(destination, from, count * sizeof(float));
            } else {
                for (size_t i = 0; i < count; ++i) {
                    destination[i] = from[i] * gain;
                }
            }
            done += span;
        }
        writeFrame += chunk;
        source += (size_t)chunk * channels;
        frameCount -= chunk;
        __atomic_store_n(&header->writeFrame, writeFrame, __ATOMIC_RELEASE);
    }
}

// Okuyucu. *ioReadFrame, okuyucunun kendi konumudur (paylaşımlı bellekte
// tutulmaz; her okuyucu bağımsızdır). En fazla maxFrames kareyi destination'a
// (interleaved) kopyalar ve kopyalanan kare sayısını döndürür. Okuyucu çok
// geride kaldıysa veya kopyalama sırasında yazar tarafından geçildiyse
// kaybedilen kareler *ioDroppedFrames'e eklenir ve konum ileri alınır.
static inline uint32_t airspeaker_ring_read(const AirSpeakerRingHeader* header, uint64_t* ioReadFrame,
                                            float* destination, uint32_t maxFrames, uint64_t* ioDroppedFrames) {
    const float* samples = airspeaker_ring_samples_const(header);
    const uint32_t capacity = AIRSPEAKER_RING_CAPACITY_FRAMES;
    const uint32_t channels = AIRSPEAKER_RING_CHANNELS;
    const uint64_t window = (uint64_t)capacity - AIRSPEAKER_RING_SAFETY_FRAMES;

    const uint64_t writeFrame = __atomic_load_n(&header->writeFrame, __ATOMIC_ACQUIRE);
    uint64_t readFrame = *ioReadFrame;
    if (readFrame > writeFrame) {
        // Yazar sıfırdan başlamış (ör. yeni bölge): canlı konuma atla.
        readFrame = writeFrame;
    }
    const uint64_t oldest = writeFrame > window ? writeFrame - window : 0;
    if (readFrame < oldest) {
        if (ioDroppedFrames != NULL) {
            *ioDroppedFrames += oldest - readFrame;
        }
        readFrame = oldest;
    }

    const uint64_t available = writeFrame - readFrame;
    const uint32_t frames = available < maxFrames ? (uint32_t)available : maxFrames;
    uint32_t done = 0;
    while (done < frames) {
        const uint32_t index = (uint32_t)((readFrame + done) % capacity);
        const uint32_t span = (frames - done) < (capacity - index) ? (frames - done) : (capacity - index);
        memcpy(destination + (size_t)done * channels, samples + (size_t)index * channels,
               (size_t)span * channels * sizeof(float));
        done += span;
    }

    // Kopyalama sırasında yazar bu bölgeye ulaştıysa veri bozulmuş olabilir; at.
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    const uint64_t writeFrameAfter = __atomic_load_n(&header->writeFrame, __ATOMIC_RELAXED);
    const uint64_t oldestAfter = writeFrameAfter > window ? writeFrameAfter - window : 0;
    if (readFrame < oldestAfter) {
        if (ioDroppedFrames != NULL) {
            *ioDroppedFrames += oldestAfter - readFrame;
        }
        *ioReadFrame = oldestAfter;
        return 0;
    }

    *ioReadFrame = readFrame + frames;
    return frames;
}

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AIRSPEAKER_IPC_H
