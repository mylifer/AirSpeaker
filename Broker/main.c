// airspeaker-broker
//
// Sürücü ile kullanıcı oturumundaki menü çubuğu uygulaması arasında aracılık
// yapan küçük LaunchDaemon.
//
// Neden gerekli? HAL eklentisi coreaudiod'un sandbox'lı sürecinde, sistem
// bootstrap alanında çalışır ve yalnızca Info.plist'te
// (AudioServerPlugIn_MachServices) adı geçen sistem Mach servislerine
// bağlanabilir. Kullanıcı oturumundaki bir uygulamanın yayınladığı servisleri
// göremez. Broker sistem alanında yayınlanır; hem sürücü hem uygulama ona
// bağlanabilir.
//
// Broker ses verisine dokunmaz. Sürücünün oluşturduğu paylaşımlı bellek
// nesnesini (xpc_shmem) saklar ve abone olan uygulamalara iletir. Sürücü
// gelip gittikçe aboneleri bilgilendirir.

#include "AirSpeakerIPC.h"

#include <dispatch/dispatch.h>
#include <os/log.h>
#include <pwd.h>
#include <stdbool.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define MAX_SUBSCRIBERS 32

static os_log_t gLog;
static dispatch_queue_t gQueue;

// Tümü gQueue üzerinde erişilir.
static xpc_connection_t gDriverPeer = NULL;  // retained
static xpc_object_t gDriverShmem = NULL;     // retained
static xpc_connection_t gSubscribers[MAX_SUBSCRIBERS];  // retained
static size_t gSubscriberCount = 0;

static bool IsTrustedDriverPeer(xpc_connection_t peer) {
    // Yalnızca coreaudiod (ve onun sürücü yardımcı süreçleri) veya root sürücü
    // olarak kaydolabilir; böylece başka bir süreç sahte ses kaynağı olamaz.
    const uid_t euid = xpc_connection_get_euid(peer);
    if (euid == 0) {
        return true;
    }
    const struct passwd* coreaudio = getpwnam("_coreaudiod");
    return coreaudio != NULL && euid == coreaudio->pw_uid;
}

static void SendDriverState(xpc_connection_t peer) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, AIRSPEAKER_MSG_KEY_TYPE, AIRSPEAKER_MSG_DRIVER_STATE);
    xpc_dictionary_set_uint64(message, AIRSPEAKER_MSG_KEY_VERSION, AIRSPEAKER_IPC_PROTOCOL_VERSION);
    xpc_dictionary_set_bool(message, AIRSPEAKER_MSG_KEY_DRIVER_ONLINE, gDriverShmem != NULL);
    if (gDriverShmem != NULL) {
        xpc_dictionary_set_value(message, AIRSPEAKER_MSG_KEY_SHMEM, gDriverShmem);
    }
    xpc_connection_send_message(peer, message);
    xpc_release(message);
}

static void BroadcastDriverState(void) {
    for (size_t i = 0; i < gSubscriberCount; ++i) {
        SendDriverState(gSubscribers[i]);
    }
}

static void ClearDriver(void) {
    if (gDriverShmem != NULL) {
        xpc_release(gDriverShmem);
        gDriverShmem = NULL;
    }
    if (gDriverPeer != NULL) {
        xpc_release(gDriverPeer);
        gDriverPeer = NULL;
    }
}

// Paylaşımlı bölgenin gerçekten AirSpeaker halka tamponu olduğunu doğrular.
static bool IsValidRing(xpc_object_t shmem) {
    void* region = NULL;
    const size_t size = xpc_shmem_map(shmem, &region);
    if (size == 0 || region == NULL) {
        return false;
    }
    const bool valid = airspeaker_ring_validate(region, size) != NULL;
    munmap(region, size);
    return valid;
}

static void HandleDriverHello(xpc_connection_t peer, xpc_object_t message) {
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    const char* status = "ok";

    xpc_object_t shmem = xpc_dictionary_get_value(message, AIRSPEAKER_MSG_KEY_SHMEM);
    if (!IsTrustedDriverPeer(peer)) {
        os_log_error(gLog, "Sürücü kaydı reddedildi: güvenilmeyen süreç (pid %d, euid %u)",
                     xpc_connection_get_pid(peer), xpc_connection_get_euid(peer));
        status = "untrusted";
    } else if (xpc_dictionary_get_uint64(message, AIRSPEAKER_MSG_KEY_VERSION) != AIRSPEAKER_IPC_PROTOCOL_VERSION) {
        os_log_error(gLog, "Sürücü kaydı reddedildi: protokol sürümü uyuşmuyor");
        status = "version-mismatch";
    } else if (shmem == NULL || xpc_get_type(shmem) != XPC_TYPE_SHMEM || !IsValidRing(shmem)) {
        os_log_error(gLog, "Sürücü kaydı reddedildi: geçersiz paylaşımlı bellek");
        status = "invalid-shmem";
    } else {
        ClearDriver();
        gDriverPeer = (xpc_connection_t)xpc_retain(peer);
        gDriverShmem = xpc_retain(shmem);
        os_log(gLog, "Sürücü kaydoldu (pid %d, euid %u); %zu aboneye bildiriliyor", xpc_connection_get_pid(peer),
               xpc_connection_get_euid(peer), gSubscriberCount);
        BroadcastDriverState();
    }

    if (reply != NULL) {
        xpc_dictionary_set_string(reply, AIRSPEAKER_MSG_KEY_STATUS, status);
        xpc_connection_send_message(peer, reply);
        xpc_release(reply);
    }
}

static void HandleSubscribe(xpc_connection_t peer) {
    for (size_t i = 0; i < gSubscriberCount; ++i) {
        if (gSubscribers[i] == peer) {
            SendDriverState(peer);
            return;
        }
    }
    if (gSubscriberCount == MAX_SUBSCRIBERS) {
        os_log_error(gLog, "Abone sınırına ulaşıldı; pid %d reddedildi", xpc_connection_get_pid(peer));
        xpc_connection_cancel(peer);
        return;
    }
    gSubscribers[gSubscriberCount++] = (xpc_connection_t)xpc_retain(peer);
    os_log(gLog, "Uygulama abone oldu (pid %d, euid %u); sürücü %{public}s", xpc_connection_get_pid(peer),
           xpc_connection_get_euid(peer), gDriverShmem != NULL ? "çevrimiçi" : "çevrimdışı");
    SendDriverState(peer);
}

static void HandlePeerGone(xpc_connection_t peer) {
    if (peer == gDriverPeer) {
        os_log(gLog, "Sürücü bağlantısı kapandı (coreaudiod yeniden başlatılmış olabilir)");
        ClearDriver();
        BroadcastDriverState();
        return;
    }
    for (size_t i = 0; i < gSubscriberCount; ++i) {
        if (gSubscribers[i] == peer) {
            xpc_release(gSubscribers[i]);
            gSubscribers[i] = gSubscribers[--gSubscriberCount];
            gSubscribers[gSubscriberCount] = NULL;
            os_log(gLog, "Uygulama aboneliği sona erdi");
            return;
        }
    }
}

static void HandlePeer(xpc_connection_t peer) {
    xpc_connection_set_target_queue(peer, gQueue);
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        const xpc_type_t type = xpc_get_type(event);
        if (type == XPC_TYPE_ERROR) {
            if (event == XPC_ERROR_CONNECTION_INVALID) {
                HandlePeerGone(peer);
            }
            return;
        }
        if (type != XPC_TYPE_DICTIONARY) {
            return;
        }
        const char* messageType = xpc_dictionary_get_string(event, AIRSPEAKER_MSG_KEY_TYPE);
        if (messageType == NULL) {
            return;
        }
        if (strcmp(messageType, AIRSPEAKER_MSG_DRIVER_HELLO) == 0) {
            HandleDriverHello(peer, event);
        } else if (strcmp(messageType, AIRSPEAKER_MSG_SUBSCRIBE) == 0) {
            HandleSubscribe(peer);
        }
    });
    xpc_connection_resume(peer);
}

int main(void) {
    gLog = os_log_create("com.mylifer.airspeaker", "broker");
    gQueue = dispatch_queue_create("com.mylifer.airspeaker.broker", DISPATCH_QUEUE_SERIAL);

    xpc_connection_t listener =
        xpc_connection_create_mach_service(AIRSPEAKER_BROKER_SERVICE, gQueue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (listener == NULL) {
        os_log_fault(gLog, "Mach servisi oluşturulamadı: %{public}s", AIRSPEAKER_BROKER_SERVICE);
        return 1;
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_CONNECTION) {
            HandlePeer((xpc_connection_t)event);
        } else {
            os_log_error(gLog, "Dinleyici hatası: %{public}s",
                         xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
        }
    });
    xpc_connection_resume(listener);
    os_log(gLog, "airspeaker-broker başladı (pid %d, euid %u)", getpid(), geteuid());

    dispatch_main();
}
