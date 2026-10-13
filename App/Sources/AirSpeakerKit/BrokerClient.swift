import CAirSpeakerIPC
import Dispatch
import XPC

/// airspeaker-broker LaunchDaemon'una XPC ile bağlanır, abone olur ve
/// sürücünün paylaşımlı belleğini alır.
final class BrokerClient {
    enum Event {
        /// Broker'a ulaşılamıyor (kurulu değil veya yeniden başlıyor).
        case brokerUnavailable(String)
        /// Broker'a bağlı, ancak sürücü kayıtlı değil (coreaudiod yeniden başlıyor olabilir).
        case driverOffline
        /// Sürücü çevrimiçi; ses bu halka tampondan okunabilir.
        case driverOnline(SharedAudioRing)
    }

    var onEvent: ((Event) -> Void)?

    private let queue: DispatchQueue
    private var connection: xpc_connection_t?
    private var reconnectScheduled = false

    /// Tüm geri çağrılar `queue` üzerinde gelir.
    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        queue.async { self.connect() }
    }

    private func connect() {
        guard connection == nil else { return }
        // PRIVILEGED: servis sistem (LaunchDaemon) bootstrap alanında aranır.
        let connection = xpc_connection_create_mach_service(
            AIRSPEAKER_BROKER_SERVICE, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        xpc_connection_set_event_handler(connection) { [weak self] event in
            self?.handle(event)
        }
        self.connection = connection
        xpc_connection_resume(connection)
        subscribe()
    }

    private func subscribe() {
        guard let connection else { return }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, AIRSPEAKER_MSG_KEY_TYPE, AIRSPEAKER_MSG_SUBSCRIBE)
        xpc_dictionary_set_uint64(message, AIRSPEAKER_MSG_KEY_VERSION, UInt64(AIRSPEAKER_IPC_PROTOCOL_VERSION))
        xpc_connection_send_message(connection, message)
    }

    private func handle(_ event: xpc_object_t) {
        let type = xpc_get_type(event)
        if type == XPC_TYPE_DICTIONARY {
            handleMessage(event)
        } else if type == XPC_TYPE_ERROR {
            if event === XPC_ERROR_CONNECTION_INTERRUPTED {
                // Broker yeniden başladı; bağlantı geçerli, yeniden abone ol.
                onEvent?(.brokerUnavailable("airspeaker-broker yeniden başlıyor"))
                subscribe()
            } else if event === XPC_ERROR_CONNECTION_INVALID {
                if let connection {
                    xpc_connection_cancel(connection)
                }
                connection = nil
                onEvent?(.brokerUnavailable("airspeaker-broker servisine ulaşılamıyor (kurulu mu?)"))
                scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ message: xpc_object_t) {
        guard let type = xpc_dictionary_get_string(message, AIRSPEAKER_MSG_KEY_TYPE),
              String(cString: type) == AIRSPEAKER_MSG_DRIVER_STATE
        else { return }

        guard xpc_dictionary_get_bool(message, AIRSPEAKER_MSG_KEY_DRIVER_ONLINE),
              let shmem = xpc_dictionary_get_value(message, AIRSPEAKER_MSG_KEY_SHMEM),
              xpc_get_type(shmem) == XPC_TYPE_SHMEM
        else {
            onEvent?(.driverOffline)
            return
        }
        guard let ring = SharedAudioRing(shmem: shmem) else {
            onEvent?(.brokerUnavailable("Sürücünün paylaşımlı belleği geçersiz (sürüm uyuşmazlığı?)"))
            return
        }
        onEvent?(.driverOnline(ring))
    }

    private func scheduleReconnect() {
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        queue.asyncAfter(deadline: .now() + 2) {
            self.reconnectScheduled = false
            self.connect()
        }
    }
}
