// Paylaşımlı halka tamponun (Shared/include/AirSpeakerIPC.h) birim testleri.
// Platformdan bağımsızdır; macOS'ta ctest ile, başka yerlerde doğrudan derlenip
// çalıştırılabilir:  cc -std=c11 -O2 -pthread -IShared/include tests/ring_buffer_test.c

#include "AirSpeakerIPC.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#define CHANNELS AIRSPEAKER_RING_CHANNELS
#define CAPACITY AIRSPEAKER_RING_CAPACITY_FRAMES
// float, 2^24'e kadar tamsayıları tam temsil eder.
#define VALUE_MODULO (1u << 23)

static int gFailures = 0;

#define CHECK(condition, ...)                                         \
    do {                                                              \
        if (!(condition)) {                                           \
            fprintf(stderr, "HATA %s:%d: ", __FILE__, __LINE__);      \
            fprintf(stderr, __VA_ARGS__);                             \
            fprintf(stderr, "\n");                                    \
            ++gFailures;                                              \
        }                                                             \
    } while (0)

static float LeftValue(uint64_t frame) { return (float)(frame % VALUE_MODULO); }
static float RightValue(uint64_t frame) { return -(float)(frame % VALUE_MODULO) - 1.0f; }

// frame'den başlayan count kareyi, kare indisini kodlayan değerlerle doldurur.
static void FillFrames(float* buffer, uint64_t firstFrame, uint32_t count) {
    for (uint32_t i = 0; i < count; ++i) {
        buffer[i * CHANNELS + 0] = LeftValue(firstFrame + i);
        buffer[i * CHANNELS + 1] = RightValue(firstFrame + i);
    }
}

// Okunan kareler firstFrame'den itibaren beklenen değerleri taşıyor mu?
static int FramesMatch(const float* buffer, uint64_t firstFrame, uint32_t count, float gain) {
    for (uint32_t i = 0; i < count; ++i) {
        if (buffer[i * CHANNELS + 0] != LeftValue(firstFrame + i) * gain ||
            buffer[i * CHANNELS + 1] != RightValue(firstFrame + i) * gain) {
            return 0;
        }
    }
    return 1;
}

static AirSpeakerRingHeader* NewRing(void) {
    void* region = malloc(airspeaker_ring_region_size());
    return airspeaker_ring_init(region, 48000);
}

static void TestInitAndValidate(void) {
    AirSpeakerRingHeader* ring = NewRing();
    CHECK(airspeaker_ring_validate(ring, airspeaker_ring_region_size()) == ring, "geçerli bölge reddedildi");
    CHECK(airspeaker_ring_validate(ring, airspeaker_ring_region_size() - 1) == NULL, "küçük bölge kabul edildi");
    CHECK(airspeaker_ring_validate(NULL, airspeaker_ring_region_size()) == NULL, "NULL kabul edildi");
    CHECK(airspeaker_ring_sample_rate(ring) == 48000, "örnekleme hızı yanlış");
    airspeaker_ring_set_sample_rate(ring, 44100);
    CHECK(airspeaker_ring_sample_rate(ring) == 44100, "örnekleme hızı güncellenmedi");
    CHECK(airspeaker_ring_write_frame(ring) == 0, "yeni tampon boş değil");
    ring->magic = 0;
    CHECK(airspeaker_ring_validate(ring, airspeaker_ring_region_size()) == NULL, "bozuk magic kabul edildi");
    free(ring);
}

static void TestSimpleReadWrite(void) {
    AirSpeakerRingHeader* ring = NewRing();
    float input[1000 * CHANNELS];
    float output[1000 * CHANNELS];
    FillFrames(input, 0, 1000);
    airspeaker_ring_write(ring, input, 1000, 1.0f);
    CHECK(airspeaker_ring_write_frame(ring) == 1000, "yazma konumu yanlış");

    uint64_t readFrame = 0;
    uint64_t dropped = 0;
    uint32_t n = airspeaker_ring_read(ring, &readFrame, output, 600, &dropped);
    CHECK(n == 600 && readFrame == 600 && dropped == 0, "ilk okuma: n=%u r=%llu", n, (unsigned long long)readFrame);
    CHECK(FramesMatch(output, 0, 600, 1.0f), "ilk okuma içeriği yanlış");

    n = airspeaker_ring_read(ring, &readFrame, output, 600, &dropped);
    CHECK(n == 400 && readFrame == 1000, "ikinci okuma: n=%u", n);
    CHECK(FramesMatch(output, 600, 400, 1.0f), "ikinci okuma içeriği yanlış");

    n = airspeaker_ring_read(ring, &readFrame, output, 600, &dropped);
    CHECK(n == 0 && dropped == 0, "boş tampondan veri okundu");
    free(ring);
}

static void TestGain(void) {
    AirSpeakerRingHeader* ring = NewRing();
    float input[256 * CHANNELS];
    float output[256 * CHANNELS];
    FillFrames(input, 0, 256);
    airspeaker_ring_write(ring, input, 256, 0.5f);
    uint64_t readFrame = 0;
    uint32_t n = airspeaker_ring_read(ring, &readFrame, output, 256, NULL);
    CHECK(n == 256 && FramesMatch(output, 0, 256, 0.5f), "kazanç uygulanmadı");

    airspeaker_ring_write(ring, input, 256, 0.0f);
    n = airspeaker_ring_read(ring, &readFrame, output, 256, NULL);
    int silent = 1;
    for (uint32_t i = 0; i < n * CHANNELS; ++i) {
        silent &= output[i] == 0.0f;
    }
    CHECK(n == 256 && silent, "sessiz (gain 0) yazım sessiz değil");
    free(ring);
}

// Tamponun etrafında defalarca dönen, tek yazımı MAX_WRITE'tan büyük
// parçalarla ilerleyen akış; okuyucu her yazımdan sonra okur.
static void TestWraparound(void) {
    AirSpeakerRingHeader* ring = NewRing();
    const uint32_t chunk = 5000;  // MAX_WRITE_FRAMES'ten büyük ve kapasiteyi bölmez
    float* input = malloc(sizeof(float) * chunk * CHANNELS);
    float* output = malloc(sizeof(float) * chunk * CHANNELS);
    uint64_t written = 0;
    uint64_t readFrame = 0;
    uint64_t dropped = 0;
    for (int i = 0; i < 200; ++i) {
        FillFrames(input, written, chunk);
        airspeaker_ring_write(ring, input, chunk, 1.0f);
        written += chunk;
        const uint64_t before = readFrame;
        uint32_t n = airspeaker_ring_read(ring, &readFrame, output, chunk, &dropped);
        CHECK(n == chunk, "tur %d: %u kare okundu", i, n);
        CHECK(FramesMatch(output, before, n, 1.0f), "tur %d: içerik yanlış", i);
    }
    CHECK(dropped == 0, "kayıp olmamalıydı: %llu", (unsigned long long)dropped);
    CHECK(written > 10ull * CAPACITY, "test tamponu yeterince dolaşmadı");
    free(input);
    free(output);
    free(ring);
}

// Okuyucu çok geride kalırsa en eski geçerli kareye atlamalı ve kaybı bildirmeli.
static void TestOverrun(void) {
    AirSpeakerRingHeader* ring = NewRing();
    const uint32_t total = CAPACITY * 3;
    float* input = malloc(sizeof(float) * total * CHANNELS);
    float* output = malloc(sizeof(float) * CAPACITY * CHANNELS);
    FillFrames(input, 0, total);
    airspeaker_ring_write(ring, input, total, 1.0f);

    uint64_t readFrame = 0;
    uint64_t dropped = 0;
    const uint64_t window = CAPACITY - AIRSPEAKER_RING_SAFETY_FRAMES;
    uint32_t n = airspeaker_ring_read(ring, &readFrame, output, CAPACITY, &dropped);
    CHECK(dropped == total - window, "kayıp sayısı yanlış: %llu", (unsigned long long)dropped);
    CHECK(n == window && readFrame == total, "taşma sonrası okuma: n=%u", n);
    CHECK(FramesMatch(output, total - window, n, 1.0f), "taşma sonrası içerik yanlış");
    free(input);
    free(output);
    free(ring);
}

// Gerçek eşzamanlılık: yazar ve okuyucu ayrı iş parçacıklarında. Okuyucunun
// kabul ettiği her kare, tam olarak beklenen değeri taşımalıdır.
typedef struct {
    AirSpeakerRingHeader* ring;
    uint64_t totalFrames;
    volatile int done;
} StressContext;

static void* StressWriter(void* argument) {
    StressContext* context = (StressContext*)argument;
    float buffer[512 * CHANNELS];
    uint64_t written = 0;
    while (written < context->totalFrames) {
        uint32_t count = 64 + (uint32_t)(written % 449);
        if (count > context->totalFrames - written) {
            count = (uint32_t)(context->totalFrames - written);
        }
        FillFrames(buffer, written, count);
        airspeaker_ring_write(context->ring, buffer, count, 1.0f);
        written += count;
    }
    __atomic_store_n(&context->done, 1, __ATOMIC_RELEASE);
    return NULL;
}

static void TestConcurrentStress(void) {
    StressContext context = {NewRing(), 8000000, 0};
    pthread_t writer;
    pthread_create(&writer, NULL, StressWriter, &context);

    float* output = malloc(sizeof(float) * 1024 * CHANNELS);
    uint64_t readFrame = 0;
    uint64_t dropped = 0;
    uint64_t received = 0;
    int corrupt = 0;
    for (;;) {
        const int finished = __atomic_load_n(&context.done, __ATOMIC_ACQUIRE);
        const uint64_t first = readFrame;
        const uint64_t droppedBefore = dropped;
        const uint32_t n = airspeaker_ring_read(context.ring, &readFrame, output, 1024, &dropped);
        const uint64_t start = first + (dropped - droppedBefore);
        if (n > 0 && !FramesMatch(output, start, n, 1.0f)) {
            ++corrupt;
        }
        received += n;
        if (finished && n == 0) {
            break;
        }
    }
    pthread_join(writer, NULL);
    CHECK(corrupt == 0, "eşzamanlı okumada %d bozuk parça", corrupt);
    CHECK(received + dropped == context.totalFrames, "kare muhasebesi tutmuyor: %llu + %llu != %llu",
          (unsigned long long)received, (unsigned long long)dropped, (unsigned long long)context.totalFrames);
    printf("  eşzamanlı: %llu kare alındı, %llu kare atlandı\n", (unsigned long long)received,
           (unsigned long long)dropped);
    free(output);
    free(context.ring);
}

int main(void) {
    TestInitAndValidate();
    TestSimpleReadWrite();
    TestGain();
    TestWraparound();
    TestOverrun();
    TestConcurrentStress();
    if (gFailures > 0) {
        fprintf(stderr, "%d test hatası\n", gFailures);
        return 1;
    }
    printf("Tüm halka tampon testleri geçti.\n");
    return 0;
}
