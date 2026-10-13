// airspeaker-check.m
//
// "iPad Ses Çıkışı" cihazının CoreAudio'ya kaydolup kaydolmadığını, istemci
// tarafındaki CoreAudio API'si üzerinden doğrulayan küçük bir Objective-C aracı.
//
//   airspeaker-check                 Cihazı ara ve bilgilerini yazdır
//   airspeaker-check --list          Tüm ses cihazlarını listele
//   airspeaker-check --wait 15       Cihaz görünene kadar en fazla 15 sn bekle
//   airspeaker-check --set-default   Cihazı varsayılan çıkış (ve sistem sesi) yap
//
// Çıkış kodu: 0 = cihaz bulundu, 1 = bulunamadı, 2 = varsayılan yapılamadı.

#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

#include "AirSpeakerConfig.h"

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    return address;
}

static NSArray<NSNumber *> *AllDevices(void) {
    AudioObjectPropertyAddress address = Address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr || size == 0) {
        return @[];
    }
    NSMutableData *buffer = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, buffer.mutableBytes) != noErr) {
        return @[];
    }
    const AudioObjectID *ids = buffer.bytes;
    NSMutableArray<NSNumber *> *devices = [NSMutableArray array];
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); ++i) {
        [devices addObject:@(ids[i])];
    }
    return devices;
}

static NSString *StringProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = Address(selector, kAudioObjectPropertyScopeGlobal);
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(object, &address, 0, NULL, &size, &value) != noErr || value == NULL) {
        return nil;
    }
    return CFBridgingRelease(value);
}

static UInt32 OutputChannelCount(AudioObjectID device) {
    AudioObjectPropertyAddress address =
        Address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size == 0) {
        return 0;
    }
    NSMutableData *buffer = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, buffer.mutableBytes) != noErr) {
        return 0;
    }
    const AudioBufferList *list = buffer.bytes;
    UInt32 channels = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        channels += list->mBuffers[i].mNumberChannels;
    }
    return channels;
}

static Float64 NominalSampleRate(AudioObjectID device) {
    AudioObjectPropertyAddress address = Address(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &rate);
    return rate;
}

static AudioObjectID DefaultDevice(AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = Address(selector, kAudioObjectPropertyScopeGlobal);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device);
    return device;
}

static OSStatus SetDefaultDevice(AudioObjectPropertySelector selector, AudioObjectID device) {
    AudioObjectPropertyAddress address = Address(selector, kAudioObjectPropertyScopeGlobal);
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, sizeof(device), &device);
}

static AudioObjectID FindDevice(NSString *uid) {
    for (NSNumber *device in AllDevices()) {
        if ([StringProperty(device.unsignedIntValue, kAudioDevicePropertyDeviceUID) isEqualToString:uid]) {
            return device.unsignedIntValue;
        }
    }
    return kAudioObjectUnknown;
}

static void PrintDevice(AudioObjectID device, BOOL highlight) {
    NSString *name = StringProperty(device, kAudioObjectPropertyName) ?: @"?";
    NSString *uid = StringProperty(device, kAudioDevicePropertyDeviceUID) ?: @"?";
    printf("%s [%u] %s\n", highlight ? "*" : " ", device, name.UTF8String);
    printf("      UID: %s | çıkış kanalı: %u | %.0f Hz\n", uid.UTF8String, OutputChannelCount(device),
           NominalSampleRate(device));
}

static void PrintUsage(void) {
    printf("Kullanım: airspeaker-check [--list] [--wait SANİYE] [--set-default]\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL list = NO;
        BOOL setDefault = NO;
        double waitSeconds = 0;

        for (int i = 1; i < argc; ++i) {
            if (strcmp(argv[i], "--list") == 0) {
                list = YES;
            } else if (strcmp(argv[i], "--set-default") == 0) {
                setDefault = YES;
            } else if (strcmp(argv[i], "--wait") == 0 && i + 1 < argc) {
                waitSeconds = atof(argv[++i]);
            } else {
                PrintUsage();
                return strcmp(argv[i], "--help") == 0 ? 0 : 64;
            }
        }

        // Komut satırı araçlarında HAL bildirimlerinin ana run loop'u beklemeden
        // kendi iş parçacığında işlenmesini sağlar (coreaudiod yeniden
        // başlatıldığında cihaz listesinin güncellenmesi için gerekli).
        CFRunLoopRef runLoop = NULL;
        AudioObjectPropertyAddress runLoopAddress =
            Address(kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal);
        AudioObjectSetPropertyData(kAudioObjectSystemObject, &runLoopAddress, 0, NULL, sizeof(runLoop), &runLoop);

        NSString *uid = @(AIRSPEAKER_DEVICE_UID);
        AudioObjectID device = FindDevice(uid);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:waitSeconds];
        while (device == kAudioObjectUnknown && deadline.timeIntervalSinceNow > 0) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
            device = FindDevice(uid);
        }

        if (list) {
            printf("Ses cihazları (* = AirSpeaker):\n");
            for (NSNumber *other in AllDevices()) {
                PrintDevice(other.unsignedIntValue, other.unsignedIntValue == device);
            }
            printf("\n");
        }

        if (device == kAudioObjectUnknown) {
            fprintf(stderr,
                    "✗ \"%s\" bulunamadı (UID: %s).\n"
                    "  Sürücü /Library/Audio/Plug-Ins/HAL altında mı? coreaudiod yeniden başlatıldı mı?\n"
                    "  Günlükler için: scripts/logs.sh\n",
                    AIRSPEAKER_DEVICE_NAME, AIRSPEAKER_DEVICE_UID);
            return 1;
        }

        printf("✓ Cihaz CoreAudio'ya kayıtlı:\n");
        PrintDevice(device, YES);

        if (setDefault) {
            OSStatus outputStatus = SetDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, device);
            OSStatus systemStatus = SetDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice, device);
            if (outputStatus != noErr || systemStatus != noErr) {
                fprintf(stderr, "✗ Varsayılan çıkış ayarlanamadı (OSStatus %d / %d)\n", (int)outputStatus,
                        (int)systemStatus);
                return 2;
            }
            printf("✓ Varsayılan çıkış cihazı olarak ayarlandı.\n");
        }

        BOOL isDefault = DefaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == device;
        printf("  Varsayılan çıkış: %s\n", isDefault ? "evet" : "hayır");
        return 0;
    }
}
