// AirSpeakerDriver.cpp
//
// "iPad Ses Çıkışı" sanal ses çıkış cihazı için CoreAudio AudioServerPlugIn
// (HAL eklentisi). Eklenti kullanıcı alanında çalışır; çekirdek uzantısı (kext)
// gerektirmez. /Library/Audio/Plug-Ins/HAL altına kurulur ve coreaudiod
// tarafından yüklenir.
//
// Nesne ağacı:
//
//   PlugIn  (kAudioObjectPlugInObject)
//     └─ Device  "iPad Ses Çıkışı"
//          ├─ Stream          çıkış, 2 kanal, Float32, interleaved
//          ├─ Volume control  çıkış, ana eleman
//          └─ Mute control    çıkış, ana eleman
//
// Aşama 1: Cihaz sisteme kaydolur ve Ses menüsünde seçilebilir. Cihaza çalınan
//          ses DoIOOperation(WriteMix) içinde alınır ve şimdilik yutulur.
// Aşama 2: WriteMix'te gelen PCM verisi kilitsiz bir halka tampona yazılacak ve
//          ayrı bir iş parçacığı tarafından UDP üzerinden yayınlanacak.

#include "AirSpeakerConfig.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/log.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <mutex>

namespace {

// MARK: - Sabitler

enum : AudioObjectID {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream_Output = 3,
    kObjectID_Volume_Output = 4,
    kObjectID_Mute_Output = 5,
};

constexpr UInt32 kChannelCount = 2;
constexpr UInt32 kBitsPerChannel = 32;
constexpr UInt32 kBytesPerFrame = kChannelCount * sizeof(Float32);

// GetZeroTimeStamp'in kaç örnekte bir yeni zaman damgası ürettiği.
constexpr UInt32 kZeroTimeStampPeriod = 16384;

constexpr Float64 kSupportedSampleRates[] = {44100.0, 48000.0, 96000.0};
constexpr UInt32 kSupportedSampleRateCount =
    sizeof(kSupportedSampleRates) / sizeof(kSupportedSampleRates[0]);

constexpr Float32 kVolumeMinDB = -96.0f;
constexpr Float32 kVolumeMaxDB = 0.0f;

constexpr UInt32 kChannelLayoutSize =
    offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription);

// MARK: - Durum

// Özellik durumunu korur (örnekleme hızı, ses seviyesi, sessiz, akış etkinliği).
std::mutex gStateMutex;
// IO / saat durumunu korur. Kilit sırası her zaman gStateMutex -> gIOMutex.
std::mutex gIOMutex;

AudioServerPlugInHostRef gHost = nullptr;
UInt32 gRefCount = 0;

// gStateMutex ile korunur.
Float64 gSampleRate = AIRSPEAKER_DEFAULT_SAMPLE_RATE;
bool gStreamIsActive = true;
Float32 gVolumeScalar = 1.0f;
bool gMuted = false;

// gIOMutex ile korunur.
Float64 gHostClockFrequency = 0.0;  // saniyedeki host tick sayısı
Float64 gHostTicksPerFrame = 0.0;
UInt64 gIORunningCount = 0;
UInt64 gAnchorHostTime = 0;
UInt64 gNumberTimeStamps = 0;

os_log_t Log() {
    static os_log_t log = os_log_create(AIRSPEAKER_LOG_SUBSYSTEM, "driver");
    return log;
}

CFStringRef MakeString(const char* utf8) {
    return CFStringCreateWithCString(kCFAllocatorDefault, utf8, kCFStringEncodingUTF8);
}

// Bu dizgeler eklenti ömrü boyunca yaşar; özellik olarak döndürülürken
// çağıran taraf için ayrıca CFRetain edilir.
CFStringRef DeviceName() {
    static const CFStringRef s = MakeString(AIRSPEAKER_DEVICE_NAME);
    return s;
}
CFStringRef Manufacturer() {
    static const CFStringRef s = MakeString(AIRSPEAKER_MANUFACTURER);
    return s;
}
CFStringRef DeviceUID() {
    static const CFStringRef s = MakeString(AIRSPEAKER_DEVICE_UID);
    return s;
}
CFStringRef ModelUID() {
    static const CFStringRef s = MakeString(AIRSPEAKER_MODEL_UID);
    return s;
}

// MARK: - Arayüz bildirimleri

HRESULT AirSpeaker_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
ULONG AirSpeaker_AddRef(void* inDriver);
ULONG AirSpeaker_Release(void* inDriver);
OSStatus AirSpeaker_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
OSStatus AirSpeaker_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
OSStatus AirSpeaker_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
OSStatus AirSpeaker_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo* inClientInfo);
OSStatus AirSpeaker_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo* inClientInfo);
OSStatus AirSpeaker_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID, UInt64 inChangeAction,
                                                     void* inChangeInfo);
OSStatus AirSpeaker_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inDeviceObjectID, UInt64 inChangeAction,
                                                   void* inChangeInfo);
Boolean AirSpeaker_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                               pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
OSStatus AirSpeaker_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                       pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                       Boolean* outIsSettable);
OSStatus AirSpeaker_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                        pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                        UInt32 inQualifierDataSize, const void* inQualifierData,
                                        UInt32* outDataSize);
OSStatus AirSpeaker_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                    pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                    UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize,
                                    UInt32* outDataSize, void* outData);
OSStatus AirSpeaker_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                    pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                    UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize,
                                    const void* inData);
OSStatus AirSpeaker_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
OSStatus AirSpeaker_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
OSStatus AirSpeaker_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime,
                                     UInt64* outSeed);
OSStatus AirSpeaker_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo,
                                      Boolean* outWillDoInPlace);
OSStatus AirSpeaker_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
OSStatus AirSpeaker_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                  AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                  void* ioMainBuffer, void* ioSecondaryBuffer);
OSStatus AirSpeaker_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

AudioServerPlugInDriverInterface gDriverInterface = {
    nullptr,  // _reserved
    AirSpeaker_QueryInterface,
    AirSpeaker_AddRef,
    AirSpeaker_Release,
    AirSpeaker_Initialize,
    AirSpeaker_CreateDevice,
    AirSpeaker_DestroyDevice,
    AirSpeaker_AddDeviceClient,
    AirSpeaker_RemoveDeviceClient,
    AirSpeaker_PerformDeviceConfigurationChange,
    AirSpeaker_AbortDeviceConfigurationChange,
    AirSpeaker_HasProperty,
    AirSpeaker_IsPropertySettable,
    AirSpeaker_GetPropertyDataSize,
    AirSpeaker_GetPropertyData,
    AirSpeaker_SetPropertyData,
    AirSpeaker_StartIO,
    AirSpeaker_StopIO,
    AirSpeaker_GetZeroTimeStamp,
    AirSpeaker_WillDoIOOperation,
    AirSpeaker_BeginIOOperation,
    AirSpeaker_DoIOOperation,
    AirSpeaker_EndIOOperation,
};
AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;
AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePtr;

// MARK: - Yardımcılar

template <typename T>
OSStatus WriteValue(const T& value, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (inDataSize < sizeof(T)) {
        return kAudioHardwareBadPropertySizeError;
    }
    std::memcpy(outData, &value, sizeof(T));
    *outDataSize = sizeof(T);
    return kAudioHardwareNoError;
}

// Dizi özellikleri: çağıranın tamponu küçükse sığdığı kadarını yazar (HAL sözleşmesi).
template <typename T>
OSStatus WriteArray(const T* items, UInt32 count, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    const UInt32 n = std::min<UInt32>(count, inDataSize / sizeof(T));
    if (n > 0) {
        std::memcpy(outData, items, n * sizeof(T));
    }
    *outDataSize = n * static_cast<UInt32>(sizeof(T));
    return kAudioHardwareNoError;
}

// CFString özellikleri: çağıran taraf döndürülen nesneyi CFRelease eder.
OSStatus WriteString(CFStringRef value, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (inDataSize < sizeof(CFStringRef)) {
        return kAudioHardwareBadPropertySizeError;
    }
    CFRetain(value);
    return WriteValue(value, inDataSize, outDataSize, outData);
}

template <typename T>
OSStatus ReadValue(const void* inData, UInt32 inDataSize, T* outValue) {
    if (inData == nullptr || inDataSize < sizeof(T)) {
        return kAudioHardwareBadPropertySizeError;
    }
    std::memcpy(outValue, inData, sizeof(T));
    return kAudioHardwareNoError;
}

void NotifyPropertiesChanged(AudioObjectID inObjectID, std::initializer_list<AudioObjectPropertySelector> inSelectors) {
    if (gHost == nullptr) {
        return;
    }
    AudioObjectPropertyAddress addresses[4];
    UInt32 count = 0;
    for (AudioObjectPropertySelector selector : inSelectors) {
        if (count < 4) {
            addresses[count++] = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        }
    }
    gHost->PropertiesChanged(gHost, inObjectID, count, addresses);
}

bool IsSupportedSampleRate(Float64 inRate) {
    return std::find(std::begin(kSupportedSampleRates), std::end(kSupportedSampleRates), inRate) !=
           std::end(kSupportedSampleRates);
}

AudioStreamBasicDescription MakeStreamFormat(Float64 inSampleRate) {
    AudioStreamBasicDescription format{};
    format.mSampleRate = inSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    format.mBytesPerPacket = kBytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kBytesPerFrame;
    format.mChannelsPerFrame = kChannelCount;
    format.mBitsPerChannel = kBitsPerChannel;
    return format;
}

bool IsSupportedStreamFormat(const AudioStreamBasicDescription& inFormat) {
    const AudioStreamBasicDescription expected = MakeStreamFormat(inFormat.mSampleRate);
    return inFormat.mFormatID == expected.mFormatID && inFormat.mFormatFlags == expected.mFormatFlags &&
           inFormat.mBytesPerPacket == expected.mBytesPerPacket &&
           inFormat.mFramesPerPacket == expected.mFramesPerPacket &&
           inFormat.mBytesPerFrame == expected.mBytesPerFrame &&
           inFormat.mChannelsPerFrame == expected.mChannelsPerFrame &&
           inFormat.mBitsPerChannel == expected.mBitsPerChannel && IsSupportedSampleRate(inFormat.mSampleRate);
}

// Örnekleme hızı değişikliği doğrudan yapılamaz: host'tan yapılandırma
// değişikliği istenir, host IO'yu durdurup PerformDeviceConfigurationChange'i
// çağırır. İstek, SetPropertyData içinden eşzamanlı yapılmamalıdır.
void RequestSampleRateChange(Float64 inNewRate) {
    os_log(Log(), "Örnekleme hızı değişikliği isteniyor: %{public}.0f Hz", inNewRate);
    const auto action = static_cast<uintptr_t>(inNewRate);
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), reinterpret_cast<void*>(action),
                     [](void* context) {
                         if (gHost != nullptr) {
                             gHost->RequestDeviceConfigurationChange(
                                 gHost, kObjectID_Device, static_cast<UInt64>(reinterpret_cast<uintptr_t>(context)),
                                 nullptr);
                         }
                     });
}

// Ses seviyesi eğrisi: genlik = skaler^3 (algısal olarak doğrusala yakın).
Float32 ScalarToDecibels(Float32 inScalar) {
    const Float32 scalar = std::clamp(inScalar, 0.0f, 1.0f);
    if (scalar <= 0.0f) {
        return kVolumeMinDB;
    }
    const Float32 db = 20.0f * std::log10(scalar * scalar * scalar);
    return std::clamp(db, kVolumeMinDB, kVolumeMaxDB);
}

Float32 DecibelsToScalar(Float32 inDecibels) {
    const Float32 db = std::clamp(inDecibels, kVolumeMinDB, kVolumeMaxDB);
    if (db <= kVolumeMinDB) {
        return 0.0f;
    }
    return std::clamp(std::cbrt(std::pow(10.0f, db / 20.0f)), 0.0f, 1.0f);
}

bool IsKnownObject(AudioObjectID inObjectID) {
    switch (inObjectID) {
        case kObjectID_PlugIn:
        case kObjectID_Device:
        case kObjectID_Stream_Output:
        case kObjectID_Volume_Output:
        case kObjectID_Mute_Output:
            return true;
        default:
            return false;
    }
}

// MARK: - PlugIn nesnesi

OSStatus PlugIn_GetPropertyDataSize(const AudioObjectPropertyAddress& inAddress, UInt32* outDataSize) {
    switch (inAddress.mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus PlugIn_GetPropertyData(const AudioObjectPropertyAddress& inAddress, UInt32 inQualifierDataSize,
                                const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize,
                                void* outData) {
    switch (inAddress.mSelector) {
        case kAudioObjectPropertyBaseClass:
            return WriteValue<AudioClassID>(kAudioObjectClassID, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyClass:
            return WriteValue<AudioClassID>(kAudioPlugInClassID, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwner:
            return WriteValue<AudioObjectID>(kAudioObjectUnknown, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyManufacturer:
            return WriteString(Manufacturer(), inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            const AudioObjectID devices[] = {kObjectID_Device};
            return WriteArray(devices, 1, inDataSize, outDataSize, outData);
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            CFStringRef uid = nullptr;
            if (ReadValue(inQualifierData, inQualifierDataSize, &uid) != kAudioHardwareNoError || uid == nullptr) {
                return kAudioHardwareBadPropertySizeError;
            }
            const AudioObjectID device = CFStringCompare(uid, DeviceUID(), 0) == kCFCompareEqualTo
                                             ? static_cast<AudioObjectID>(kObjectID_Device)
                                             : static_cast<AudioObjectID>(kAudioObjectUnknown);
            return WriteValue(device, inDataSize, outDataSize, outData);
        }
        case kAudioPlugInPropertyResourceBundle:
            // Kaynaklar (ör. simge) eklenti paketinin kökünden aranır.
            return WriteString(CFSTR(""), inDataSize, outDataSize, outData);
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - Device nesnesi

UInt32 Device_StreamCount(AudioObjectPropertyScope inScope) {
    return inScope == kAudioObjectPropertyScopeInput ? 0 : 1;
}

UInt32 Device_OwnedObjects(AudioObjectPropertyScope inScope, AudioObjectID* outObjects) {
    if (inScope == kAudioObjectPropertyScopeInput) {
        return 0;
    }
    outObjects[0] = kObjectID_Stream_Output;
    outObjects[1] = kObjectID_Volume_Output;
    outObjects[2] = kObjectID_Mute_Output;
    return 3;
}

OSStatus Device_GetPropertyDataSize(const AudioObjectPropertyAddress& inAddress, UInt32* outDataSize) {
    switch (inAddress.mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyConfigurationApplication:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID objects[3];
            *outDataSize = Device_OwnedObjects(inAddress.mScope, objects) * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyStreams:
            *outDataSize = Device_StreamCount(inAddress.mScope) * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            *outDataSize = 2 * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = kSupportedSampleRateCount * sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = kChannelLayoutSize;
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus Device_GetPropertyData(const AudioObjectPropertyAddress& inAddress, UInt32 inDataSize,
                                UInt32* outDataSize, void* outData) {
    const bool isInputScope = inAddress.mScope == kAudioObjectPropertyScopeInput;

    switch (inAddress.mSelector) {
        case kAudioObjectPropertyBaseClass:
            return WriteValue<AudioClassID>(kAudioObjectClassID, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyClass:
            return WriteValue<AudioClassID>(kAudioDeviceClassID, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwner:
            return WriteValue<AudioObjectID>(kObjectID_PlugIn, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyName:
            return WriteString(DeviceName(), inDataSize, outDataSize, outData);
        case kAudioObjectPropertyManufacturer:
            return WriteString(Manufacturer(), inDataSize, outDataSize, outData);
        case kAudioDevicePropertyDeviceUID:
            return WriteString(DeviceUID(), inDataSize, outDataSize, outData);
        case kAudioDevicePropertyModelUID:
            return WriteString(ModelUID(), inDataSize, outDataSize, outData);
        case kAudioDevicePropertyConfigurationApplication:
            return WriteString(CFSTR("com.apple.audio.AudioMIDISetup"), inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID objects[3];
            const UInt32 count = Device_OwnedObjects(inAddress.mScope, objects);
            return WriteArray(objects, count, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyStreams: {
            const AudioObjectID streams[] = {kObjectID_Stream_Output};
            return WriteArray(streams, Device_StreamCount(inAddress.mScope), inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyControlList: {
            const AudioObjectID controls[] = {kObjectID_Volume_Output, kObjectID_Mute_Output};
            return WriteArray(controls, 2, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyRelatedDevices: {
            const AudioObjectID devices[] = {kObjectID_Device};
            return WriteArray(devices, 1, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyTransportType:
            return WriteValue<UInt32>(kAudioDeviceTransportTypeVirtual, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyClockDomain:
            return WriteValue<UInt32>(0, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyDeviceIsAlive:
            return WriteValue<UInt32>(1, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyDeviceIsRunning: {
            UInt32 isRunning;
            {
                std::lock_guard<std::mutex> lock(gIOMutex);
                isRunning = gIORunningCount > 0 ? 1 : 0;
            }
            return WriteValue(isRunning, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            // Yalnızca çıkış yönünde varsayılan cihaz olabilir.
            return WriteValue<UInt32>(isInputScope ? 0 : 1, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            return WriteValue<UInt32>(0, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyIsHidden:
            return WriteValue<UInt32>(0, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return WriteValue<UInt32>(kZeroTimeStampPeriod, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyNominalSampleRate: {
            Float64 rate;
            {
                std::lock_guard<std::mutex> lock(gStateMutex);
                rate = gSampleRate;
            }
            return WriteValue(rate, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange ranges[kSupportedSampleRateCount];
            for (UInt32 i = 0; i < kSupportedSampleRateCount; ++i) {
                ranges[i].mMinimum = kSupportedSampleRates[i];
                ranges[i].mMaximum = kSupportedSampleRates[i];
            }
            return WriteArray(ranges, kSupportedSampleRateCount, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            const UInt32 channels[2] = {1, 2};
            if (inDataSize < sizeof(channels)) {
                return kAudioHardwareBadPropertySizeError;
            }
            return WriteArray(channels, 2, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            if (inDataSize < kChannelLayoutSize) {
                return kAudioHardwareBadPropertySizeError;
            }
            std::memset(outData, 0, kChannelLayoutSize);
            auto* layout = static_cast<AudioChannelLayout*>(outData);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mChannelBitmap = 0;
            layout->mNumberChannelDescriptions = kChannelCount;
            AudioChannelDescription* descriptions = layout->mChannelDescriptions;
            descriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            descriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = kChannelLayoutSize;
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

bool Device_IsPropertySettable(const AudioObjectPropertyAddress& inAddress) {
    return inAddress.mSelector == kAudioDevicePropertyNominalSampleRate;
}

OSStatus Device_SetPropertyData(const AudioObjectPropertyAddress& inAddress, UInt32 inDataSize,
                                const void* inData) {
    switch (inAddress.mSelector) {
        case kAudioDevicePropertyNominalSampleRate: {
            Float64 newRate = 0.0;
            if (OSStatus err = ReadValue(inData, inDataSize, &newRate); err != kAudioHardwareNoError) {
                return err;
            }
            if (!IsSupportedSampleRate(newRate)) {
                return kAudioHardwareIllegalOperationError;
            }
            bool changed;
            {
                std::lock_guard<std::mutex> lock(gStateMutex);
                changed = newRate != gSampleRate;
            }
            if (changed) {
                RequestSampleRateChange(newRate);
            }
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - Stream nesnesi

OSStatus Stream_GetPropertyDataSize(const AudioObjectPropertyAddress& inAddress, UInt32* outDataSize) {
    switch (inAddress.mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = kSupportedSampleRateCount * sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus Stream_GetPropertyData(const AudioObjectPropertyAddress& inAddress, UInt32 inDataSize,
                                UInt32* outDataSize, void* outData) {
    switch (inAddress.mSelector) {
        case kAudioObjectPropertyBaseClass:
            return WriteValue<AudioClassID>(kAudioObjectClassID, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyClass:
            return WriteValue<AudioClassID>(kAudioStreamClassID, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwner:
            return WriteValue<AudioObjectID>(kObjectID_Device, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive: {
            UInt32 isActive;
            {
                std::lock_guard<std::mutex> lock(gStateMutex);
                isActive = gStreamIsActive ? 1 : 0;
            }
            return WriteValue(isActive, inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyDirection:
            // 0 = çıkış, 1 = giriş
            return WriteValue<UInt32>(0, inDataSize, outDataSize, outData);
        case kAudioStreamPropertyTerminalType:
            return WriteValue<UInt32>(kAudioStreamTerminalTypeSpeaker, inDataSize, outDataSize, outData);
        case kAudioStreamPropertyStartingChannel:
            return WriteValue<UInt32>(1, inDataSize, outDataSize, outData);
        case kAudioStreamPropertyLatency:
            return WriteValue<UInt32>(0, inDataSize, outDataSize, outData);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            Float64 rate;
            {
                std::lock_guard<std::mutex> lock(gStateMutex);
                rate = gSampleRate;
            }
            return WriteValue(MakeStreamFormat(rate), inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription formats[kSupportedSampleRateCount];
            for (UInt32 i = 0; i < kSupportedSampleRateCount; ++i) {
                formats[i].mFormat = MakeStreamFormat(kSupportedSampleRates[i]);
                formats[i].mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                formats[i].mSampleRateRange.mMaximum = kSupportedSampleRates[i];
            }
            return WriteArray(formats, kSupportedSampleRateCount, inDataSize, outDataSize, outData);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

bool Stream_IsPropertySettable(const AudioObjectPropertyAddress& inAddress) {
    switch (inAddress.mSelector) {
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return true;
        default:
            return false;
    }
}

OSStatus Stream_SetPropertyData(const AudioObjectPropertyAddress& inAddress, UInt32 inDataSize,
                                const void* inData) {
    switch (inAddress.mSelector) {
        case kAudioStreamPropertyIsActive: {
            UInt32 value = 0;
            if (OSStatus err = ReadValue(inData, inDataSize, &value); err != kAudioHardwareNoError) {
                return err;
            }
            bool changed;
            {
                std::lock_guard<std::mutex> lock(gStateMutex);
                changed = gStreamIsActive != (value != 0);
                gStreamIsActive = value != 0;
            }
            if (changed) {
                NotifyPropertiesChanged(kObjectID_Stream_Output, {kAudioStreamPropertyIsActive});
            }
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription format{};
            if (OSStatus err = ReadValue(inData, inDataSize, &format); err != kAudioHardwareNoError) {
                return err;
            }
            if (!IsSupportedStreamFormat(format)) {
                return kAudioDeviceUnsupportedFormatError;
            }
            bool changed;
            {
                std::lock_guard<std::mutex> lock(gStateMutex);
                changed = format.mSampleRate != gSampleRate;
            }
            if (changed) {
                RequestSampleRateChange(format.mSampleRate);
            }
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - Volume control nesnesi

OSStatus Volume_GetPropertyDataSize(const AudioObjectPropertyAddress& inAddress, UInt32* outDataSize) {
    switch (inAddress.mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
            *outDataSize = sizeof(AudioObjectPropertyScope);
            return kAudioHardwareNoError;
        case kAudioControlPropertyElement:
            *outDataSize = sizeof(AudioObjectPropertyElement);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            *outDataSize = sizeof(Float32);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelRange:
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus Volume_GetPropertyData(const AudioObjectPropertyAddress& inAddress, UInt32 inDataSize,
                                UInt32* outDataSize, void* outData) {
    switch (inAddress.mSelector) {
        case kAudioObjectPropertyBaseClass:
            return WriteValue<AudioClassID>(kAudioLevelControlClassID, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyClass:
            return WriteValue<AudioClassID>(kAudioVolumeControlClassID, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwner:
            return WriteValue<AudioObjectID>(kObjectID_Device, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
            return WriteValue<AudioObjectPropertyScope>(kAudioObjectPropertyScopeOutput, inDataSize, outDataSize,
                                                        outData);
        case kAudioControlPropertyElement:
            return WriteValue<AudioObjectPropertyElement>(kAudioObjectPropertyElementMain, inDataSize, outDataSize,
                                                          outData);
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue: {
            Float32 scalar;
            {
                std::lock_guard<std::mutex> lock(gStateMutex);
                scalar = gVolumeScalar;
            }
            const Float32 value = inAddress.mSelector == kAudioLevelControlPropertyScalarValue
                                      ? scalar
                                      : ScalarToDecibels(scalar);
            return WriteValue(value, inDataSize, outDataSize, outData);
        }
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange range;
            range.mMinimum = kVolumeMinDB;
            range.mMaximum = kVolumeMaxDB;
            return WriteValue(range, inDataSize, outDataSize, outData);
        }
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            // Bu iki özellikte outData hem girdi hem çıktıdır.
            Float32 value = 0.0f;
            if (OSStatus err = ReadValue(outData, inDataSize, &value); err != kAudioHardwareNoError) {
                return err;
            }
            value = inAddress.mSelector == kAudioLevelControlPropertyConvertScalarToDecibels
                        ? ScalarToDecibels(value)
                        : DecibelsToScalar(value);
            return WriteValue(value, inDataSize, outDataSize, outData);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

bool Volume_IsPropertySettable(const AudioObjectPropertyAddress& inAddress) {
    return inAddress.mSelector == kAudioLevelControlPropertyScalarValue ||
           inAddress.mSelector == kAudioLevelControlPropertyDecibelValue;
}

OSStatus Volume_SetPropertyData(const AudioObjectPropertyAddress& inAddress, UInt32 inDataSize,
                                const void* inData) {
    switch (inAddress.mSelector) {
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue: {
            Float32 value = 0.0f;
            if (OSStatus err = ReadValue(inData, inDataSize, &value); err != kAudioHardwareNoError) {
                return err;
            }
            const Float32 scalar = inAddress.mSelector == kAudioLevelControlPropertyScalarValue
                                       ? std::clamp(value, 0.0f, 1.0f)
                                       : DecibelsToScalar(value);
            bool changed;
            {
                std::lock_guard<std::mutex> lock(gStateMutex);
                changed = scalar != gVolumeScalar;
                gVolumeScalar = scalar;
            }
            if (changed) {
                NotifyPropertiesChanged(kObjectID_Volume_Output, {kAudioLevelControlPropertyScalarValue,
                                                                  kAudioLevelControlPropertyDecibelValue});
            }
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - Mute control nesnesi

OSStatus Mute_GetPropertyDataSize(const AudioObjectPropertyAddress& inAddress, UInt32* outDataSize) {
    switch (inAddress.mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
            *outDataSize = sizeof(AudioObjectPropertyScope);
            return kAudioHardwareNoError;
        case kAudioControlPropertyElement:
            *outDataSize = sizeof(AudioObjectPropertyElement);
            return kAudioHardwareNoError;
        case kAudioBooleanControlPropertyValue:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus Mute_GetPropertyData(const AudioObjectPropertyAddress& inAddress, UInt32 inDataSize, UInt32* outDataSize,
                              void* outData) {
    switch (inAddress.mSelector) {
        case kAudioObjectPropertyBaseClass:
            return WriteValue<AudioClassID>(kAudioBooleanControlClassID, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyClass:
            return WriteValue<AudioClassID>(kAudioMuteControlClassID, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwner:
            return WriteValue<AudioObjectID>(kObjectID_Device, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
            return WriteValue<AudioObjectPropertyScope>(kAudioObjectPropertyScopeOutput, inDataSize, outDataSize,
                                                        outData);
        case kAudioControlPropertyElement:
            return WriteValue<AudioObjectPropertyElement>(kAudioObjectPropertyElementMain, inDataSize, outDataSize,
                                                          outData);
        case kAudioBooleanControlPropertyValue: {
            UInt32 muted;
            {
                std::lock_guard<std::mutex> lock(gStateMutex);
                muted = gMuted ? 1 : 0;
            }
            return WriteValue(muted, inDataSize, outDataSize, outData);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

bool Mute_IsPropertySettable(const AudioObjectPropertyAddress& inAddress) {
    return inAddress.mSelector == kAudioBooleanControlPropertyValue;
}

OSStatus Mute_SetPropertyData(const AudioObjectPropertyAddress& inAddress, UInt32 inDataSize, const void* inData) {
    switch (inAddress.mSelector) {
        case kAudioBooleanControlPropertyValue: {
            UInt32 value = 0;
            if (OSStatus err = ReadValue(inData, inDataSize, &value); err != kAudioHardwareNoError) {
                return err;
            }
            bool changed;
            {
                std::lock_guard<std::mutex> lock(gStateMutex);
                changed = gMuted != (value != 0);
                gMuted = value != 0;
            }
            if (changed) {
                NotifyPropertiesChanged(kObjectID_Mute_Output, {kAudioBooleanControlPropertyValue});
            }
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - Nesne yönlendirme

OSStatus GetPropertyDataSizeFor(AudioObjectID inObjectID, const AudioObjectPropertyAddress& inAddress,
                                UInt32* outDataSize) {
    switch (inObjectID) {
        case kObjectID_PlugIn:
            return PlugIn_GetPropertyDataSize(inAddress, outDataSize);
        case kObjectID_Device:
            return Device_GetPropertyDataSize(inAddress, outDataSize);
        case kObjectID_Stream_Output:
            return Stream_GetPropertyDataSize(inAddress, outDataSize);
        case kObjectID_Volume_Output:
            return Volume_GetPropertyDataSize(inAddress, outDataSize);
        case kObjectID_Mute_Output:
            return Mute_GetPropertyDataSize(inAddress, outDataSize);
        default:
            return kAudioHardwareBadObjectError;
    }
}

// Bir özelliğin var olup olmadığı, boyutunun bilinip bilinmemesiyle aynı
// şeydir; böylece desteklenen özellik listesi tek yerde tutulur.
bool HasPropertyFor(AudioObjectID inObjectID, const AudioObjectPropertyAddress& inAddress) {
    UInt32 size = 0;
    return GetPropertyDataSizeFor(inObjectID, inAddress, &size) == kAudioHardwareNoError;
}

bool IsPropertySettableFor(AudioObjectID inObjectID, const AudioObjectPropertyAddress& inAddress) {
    switch (inObjectID) {
        case kObjectID_Device:
            return Device_IsPropertySettable(inAddress);
        case kObjectID_Stream_Output:
            return Stream_IsPropertySettable(inAddress);
        case kObjectID_Volume_Output:
            return Volume_IsPropertySettable(inAddress);
        case kObjectID_Mute_Output:
            return Mute_IsPropertySettable(inAddress);
        default:
            return false;
    }
}

// MARK: - IUnknown

HRESULT AirSpeaker_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == nullptr) {
        return static_cast<HRESULT>(kAudioHardwareIllegalOperationError);
    }
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, inUUID);
    if (requested == nullptr) {
        return static_cast<HRESULT>(kAudioHardwareIllegalOperationError);
    }
    HRESULT result = static_cast<HRESULT>(E_NOINTERFACE);
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        {
            std::lock_guard<std::mutex> lock(gStateMutex);
            ++gRefCount;
        }
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

ULONG AirSpeaker_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) {
        return 0;
    }
    std::lock_guard<std::mutex> lock(gStateMutex);
    if (gRefCount < UINT32_MAX) {
        ++gRefCount;
    }
    return gRefCount;
}

ULONG AirSpeaker_Release(void* inDriver) {
    if (inDriver != gDriverRef) {
        return 0;
    }
    // Sürücü nesnesi statiktir; sayaç sıfıra inse bile serbest bırakılacak bir şey yoktur.
    std::lock_guard<std::mutex> lock(gStateMutex);
    if (gRefCount > 0) {
        --gRefCount;
    }
    return gRefCount;
}

// MARK: - Temel işlemler

OSStatus AirSpeaker_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    gHost = inHost;

    mach_timebase_info_data_t timebase{};
    mach_timebase_info(&timebase);
    Float64 sampleRate;
    {
        std::lock_guard<std::mutex> stateLock(gStateMutex);
        sampleRate = gSampleRate;
    }
    {
        std::lock_guard<std::mutex> ioLock(gIOMutex);
        gHostClockFrequency = static_cast<Float64>(timebase.denom) / static_cast<Float64>(timebase.numer) * 1.0e9;
        gHostTicksPerFrame = gHostClockFrequency / sampleRate;
    }

    os_log(Log(), "AirSpeaker HAL eklentisi yüklendi: \"%{public}s\" (%{public}.0f Hz)", AIRSPEAKER_DEVICE_NAME,
           sampleRate);
    return kAudioHardwareNoError;
}

OSStatus AirSpeaker_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*,
                                 AudioObjectID*) {
    // Cihaz statiktir; istemcilerin yeni cihaz oluşturması desteklenmez.
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus AirSpeaker_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus AirSpeaker_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo*) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

OSStatus AirSpeaker_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo*) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

OSStatus AirSpeaker_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID, UInt64 inChangeAction,
                                                     void*) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    // RequestSampleRateChange, yeni örnekleme hızını inChangeAction olarak gönderir.
    const Float64 newRate = static_cast<Float64>(inChangeAction);
    if (!IsSupportedSampleRate(newRate)) {
        return kAudioHardwareIllegalOperationError;
    }
    {
        std::lock_guard<std::mutex> stateLock(gStateMutex);
        std::lock_guard<std::mutex> ioLock(gIOMutex);
        gSampleRate = newRate;
        gHostTicksPerFrame = gHostClockFrequency / newRate;
    }
    os_log(Log(), "Örnekleme hızı değişti: %{public}.0f Hz", newRate);
    return kAudioHardwareNoError;
}

OSStatus AirSpeaker_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inDeviceObjectID, UInt64, void*) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

// MARK: - Özellik işlemleri

Boolean AirSpeaker_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t,
                               const AudioObjectPropertyAddress* inAddress) {
    if (inDriver != gDriverRef || inAddress == nullptr) {
        return false;
    }
    return HasPropertyFor(inObjectID, *inAddress);
}

OSStatus AirSpeaker_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t,
                                       const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    if (inDriver != gDriverRef || !IsKnownObject(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == nullptr || outIsSettable == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!HasPropertyFor(inObjectID, *inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    *outIsSettable = IsPropertySettableFor(inObjectID, *inAddress);
    return kAudioHardwareNoError;
}

OSStatus AirSpeaker_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t,
                                        const AudioObjectPropertyAddress* inAddress, UInt32, const void*,
                                        UInt32* outDataSize) {
    if (inDriver != gDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == nullptr || outDataSize == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    return GetPropertyDataSizeFor(inObjectID, *inAddress, outDataSize);
}

OSStatus AirSpeaker_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t,
                                    const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                    const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize,
                                    void* outData) {
    if (inDriver != gDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == nullptr || outDataSize == nullptr || outData == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    switch (inObjectID) {
        case kObjectID_PlugIn:
            return PlugIn_GetPropertyData(*inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize,
                                          outData);
        case kObjectID_Device:
            return Device_GetPropertyData(*inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Stream_Output:
            return Stream_GetPropertyData(*inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Volume_Output:
            return Volume_GetPropertyData(*inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Mute_Output:
            return Mute_GetPropertyData(*inAddress, inDataSize, outDataSize, outData);
        default:
            return kAudioHardwareBadObjectError;
    }
}

OSStatus AirSpeaker_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t,
                                    const AudioObjectPropertyAddress* inAddress, UInt32, const void*,
                                    UInt32 inDataSize, const void* inData) {
    if (inDriver != gDriverRef || !IsKnownObject(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!HasPropertyFor(inObjectID, *inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    if (!IsPropertySettableFor(inObjectID, *inAddress)) {
        return kAudioHardwareUnsupportedOperationError;
    }
    switch (inObjectID) {
        case kObjectID_Device:
            return Device_SetPropertyData(*inAddress, inDataSize, inData);
        case kObjectID_Stream_Output:
            return Stream_SetPropertyData(*inAddress, inDataSize, inData);
        case kObjectID_Volume_Output:
            return Volume_SetPropertyData(*inAddress, inDataSize, inData);
        case kObjectID_Mute_Output:
            return Mute_SetPropertyData(*inAddress, inDataSize, inData);
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - IO işlemleri

OSStatus AirSpeaker_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    std::lock_guard<std::mutex> lock(gIOMutex);
    if (gIORunningCount == UINT64_MAX) {
        return kAudioHardwareIllegalOperationError;
    }
    if (gIORunningCount == 0) {
        // İlk istemci: saati sıfırdan başlat.
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        os_log(Log(), "IO başladı");
    }
    ++gIORunningCount;
    return kAudioHardwareNoError;
}

OSStatus AirSpeaker_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    std::lock_guard<std::mutex> lock(gIOMutex);
    if (gIORunningCount == 0) {
        return kAudioHardwareIllegalOperationError;
    }
    --gIORunningCount;
    if (gIORunningCount == 0) {
        os_log(Log(), "IO durdu");
    }
    return kAudioHardwareNoError;
}

// Gerçek bir donanım saati olmadığından cihazın saati host saatinden
// (mach_absolute_time) türetilir: her kZeroTimeStampPeriod örnekte bir,
// örnek zamanı ile host zamanını eşleyen yeni bir "sıfır" damgası verilir.
OSStatus AirSpeaker_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32,
                                     Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    std::lock_guard<std::mutex> lock(gIOMutex);

    const UInt64 currentHostTime = mach_absolute_time();
    const Float64 hostTicksPerPeriod = gHostTicksPerFrame * static_cast<Float64>(kZeroTimeStampPeriod);
    const Float64 nextOffset = static_cast<Float64>(gNumberTimeStamps + 1) * hostTicksPerPeriod;
    const UInt64 nextHostTime = gAnchorHostTime + static_cast<UInt64>(nextOffset);
    if (nextHostTime <= currentHostTime) {
        ++gNumberTimeStamps;
    }

    *outSampleTime = static_cast<Float64>(gNumberTimeStamps * kZeroTimeStampPeriod);
    *outHostTime =
        gAnchorHostTime + static_cast<UInt64>(static_cast<Float64>(gNumberTimeStamps) * hostTicksPerPeriod);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

OSStatus AirSpeaker_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32,
                                      UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    // Yalnızca çıkış karışımını (WriteMix) alıyoruz; işlem yerinde yapılır.
    const bool willDo = inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo != nullptr) {
        *outWillDo = willDo;
    }
    if (outWillDoInPlace != nullptr) {
        *outWillDoInPlace = true;
    }
    return kAudioHardwareNoError;
}

OSStatus AirSpeaker_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32,
                                     UInt32, UInt32, const AudioServerPlugInIOCycleInfo*) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

OSStatus AirSpeaker_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                  AudioObjectID inStreamObjectID, UInt32, UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                  void* ioMainBuffer, void*) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device ||
        inStreamObjectID != kObjectID_Stream_Output) {
        return kAudioHardwareBadObjectError;
    }
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        // ioMainBuffer: inIOBufferFrameSize kare, interleaved Float32 stereo
        // (kBytesPerFrame bayt/kare). Örnek zamanı:
        // inIOCycleInfo->mOutputTime.mSampleTime.
        //
        // AŞAMA 2: Bu fonksiyon gerçek zamanlı IO iş parçacığında çalışır.
        // Burada bellek ayırma, kilit bekleme veya ağ çağrısı yapılmamalı;
        // veri kilitsiz bir halka tampona kopyalanmalı ve UDP gönderimi ayrı
        // bir iş parçacığında yapılmalıdır.
        (void)ioMainBuffer;
        (void)inIOBufferFrameSize;
        (void)inIOCycleInfo;
    }
    return kAudioHardwareNoError;
}

OSStatus AirSpeaker_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32,
                                   UInt32, UInt32, const AudioServerPlugInIOCycleInfo*) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

}  // namespace

// MARK: - Fabrika fonksiyonu
//
// Info.plist'teki CFPlugInFactories girdisi bu sembolü gösterir. coreaudiod,
// eklenti paketini yükledikten sonra bu fonksiyonu AudioServerPlugIn tür
// UUID'si ile çağırır.

extern "C" __attribute__((visibility("default"))) void* AirSpeaker_Create(CFAllocatorRef inAllocator,
                                                                          CFUUIDRef inRequestedTypeUUID);

extern "C" void* AirSpeaker_Create(CFAllocatorRef, CFUUIDRef inRequestedTypeUUID) {
    if (inRequestedTypeUUID != nullptr && CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return nullptr;
}
