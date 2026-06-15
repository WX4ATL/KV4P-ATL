/*
KV4P/ATL BLE bridge
Copyright (C) 2026 Blake Ross WX4ATL

SPDX-License-Identifier: GPL-3.0-or-later
*/
#include "kv4p_ble_bridge.h"
#include <esp_gap_ble_api.h>
#include <esp_task_wdt.h>

extern volatile bool kv4pBleUrgentPttOffPending;

namespace {
static constexpr uint8_t KISS_FEND = 0xC0;
static constexpr uint8_t KISS_FESC = 0xDB;
static constexpr uint8_t KISS_TFEND = 0xDC;
static constexpr uint8_t KISS_TFESC = 0xDD;
static constexpr uint8_t KISS_CMD_SETHARDWARE = 0x06;
static constexpr uint8_t KV4P_PROTOCOL_VERSION = 0x01;
static constexpr uint8_t COMMAND_HOST_DESIRED_STATE = 0x0D;
static constexpr uint16_t HOST_STATE_PTT_REQUESTED = 0x0002;
static constexpr uint8_t KV4P_VENDOR_PREFIX[] = {'K', 'V', '4', 'P'};
static constexpr size_t HOST_DESIRED_STATE_LEN = 22;
static constexpr size_t HOST_DESIRED_STATE_FLAGS_OFFSET = 8;
static constexpr uint16_t APPLE_CONN_INTERVAL_15_MS = 12;
static constexpr uint16_t APPLE_CONN_INTERVAL_30_MS = 24;
static constexpr uint16_t BLE_SUPERVISION_TIMEOUT_4S = 400;
static constexpr uint32_t BLE_RE_ADVERTISE_AFTER_DISCONNECT_MS = 500;
static constexpr uint32_t APRS_TNC_KEEPALIVE_INTERVAL_MS = 1000;

bool isUrgentPttOffFrame(const uint8_t *data, size_t len) {
  if (data == nullptr || len == 0) {
    return false;
  }

  uint8_t decoded[1 + sizeof(KV4P_VENDOR_PREFIX) + 2 + HOST_DESIRED_STATE_LEN] = {};
  size_t decodedLen = 0;
  bool inFrame = false;
  bool escaped = false;

  for (size_t index = 0; index < len; index++) {
    const uint8_t byte = data[index];
    if (byte == KISS_FEND) {
      if (inFrame && decodedLen > 0) {
        break;
      }
      inFrame = true;
      escaped = false;
      decodedLen = 0;
      continue;
    }
    if (!inFrame) {
      continue;
    }

    uint8_t decodedByte = byte;
    if (escaped) {
      if (byte == KISS_TFEND) {
        decodedByte = KISS_FEND;
      } else if (byte == KISS_TFESC) {
        decodedByte = KISS_FESC;
      } else {
        return false;
      }
      escaped = false;
    } else if (byte == KISS_FESC) {
      escaped = true;
      continue;
    }

    if (decodedLen >= sizeof(decoded)) {
      return false;
    }
    decoded[decodedLen++] = decodedByte;
  }

  const size_t expectedLen = sizeof(decoded);
  if (decodedLen != expectedLen || decoded[0] != KISS_CMD_SETHARDWARE) {
    return false;
  }
  if (memcmp(decoded + 1, KV4P_VENDOR_PREFIX, sizeof(KV4P_VENDOR_PREFIX)) != 0) {
    return false;
  }
  if (decoded[5] != KV4P_PROTOCOL_VERSION || decoded[6] != COMMAND_HOST_DESIRED_STATE) {
    return false;
  }

  const size_t flagsOffset = 1 + sizeof(KV4P_VENDOR_PREFIX) + 2 + HOST_DESIRED_STATE_FLAGS_OFFSET;
  const uint16_t flags = static_cast<uint16_t>(decoded[flagsOffset])
    | (static_cast<uint16_t>(decoded[flagsOffset + 1]) << 8);
  return (flags & HOST_STATE_PTT_REQUESTED) == 0;
}

class ServerCallbacks final : public BLEServerCallbacks {
public:
  ServerCallbacks(KV4PBleBridgeStream &stream, KV4PBleBridgeStream *aprsTncStream, KV4PBleBridge &bridge)
    : _stream(stream), _aprsTncStream(aprsTncStream), _bridge(bridge) {}

  void onConnect(BLEServer *) override {
    // Arduino-ESP32 invokes this legacy callback before the parameterized
    // callback. Arm the streams here, but count the central only once below.
    _bridge.cancelAdvertisingRestart();
    armStreams();
  }

  void onConnect(BLEServer *server, esp_ble_gatts_cb_param_t *param) override {
    _bridge.cancelAdvertisingRestart();
    _bridge.noteClientConnected();
    armStreams();
    if (server != nullptr && param != nullptr) {
      // Apple accepts a 15 ms minimum when the maximum is at least 30 ms. A
      // range is more stable for third-party APRS apps than forcing 15/15 ms.
      server->updateConnParams(
        param->connect.remote_bda,
        APPLE_CONN_INTERVAL_15_MS,
        APPLE_CONN_INTERVAL_30_MS,
        0,
        BLE_SUPERVISION_TIMEOUT_4S
      );
      // Match the 247-byte ATT MTU path with the largest BLE data PDU the
      // ESP32 stack can request, reducing link-layer fragmentation jitter.
      esp_ble_gap_set_pkt_data_len(param->connect.remote_bda, 251);
    }
  }

  void onDisconnect(BLEServer *server) override {
    const bool clientsRemain = _bridge.noteClientDisconnected();
    if (!clientsRemain) {
      _stream.setConnected(false);
      if (_aprsTncStream != nullptr) {
        _aprsTncStream->setConnected(false);
      }
      _stream.setNotifyPayloadSize(20);
      if (_aprsTncStream != nullptr) {
        _aprsTncStream->setNotifyPayloadSize(20);
      }
    } else {
      armStreams();
    }
    if (server != nullptr) {
      server->startAdvertising();
    }
    // ESP32 BLE UART examples restart advertising after the disconnect event
    // has settled. Keep the immediate restart, then retry once from loop().
    _bridge.requestAdvertisingRestart(BLE_RE_ADVERTISE_AFTER_DISCONNECT_MS, clientsRemain);
  }

  void onMtuChanged(BLEServer *, esp_ble_gatts_cb_param_t *param) override {
    if (param == nullptr) {
      return;
    }
    // BLE notification values can carry MTU - 3 bytes. Store the server-side
    // negotiated value directly; the global BLEDevice peer list can remain at
    // the default 23-byte MTU and would force wasteful 20-byte audio chunks.
    const size_t payloadSize = param->mtu.mtu > 3 ? param->mtu.mtu - 3 : 20;
    _stream.setNotifyPayloadSize(payloadSize);
    if (_aprsTncStream != nullptr) {
      _aprsTncStream->setNotifyPayloadSize(payloadSize);
    }
  }

private:
  void armStreams() {
    _stream.setConnected(true);
    if (_aprsTncStream != nullptr) {
      _aprsTncStream->setConnected(true);
    }
    _stream.setNotifyPayloadSize(20);
    if (_aprsTncStream != nullptr) {
      _aprsTncStream->setNotifyPayloadSize(20);
    }
  }

  KV4PBleBridgeStream &_stream;
  KV4PBleBridgeStream *_aprsTncStream;
  KV4PBleBridge &_bridge;
};

class WriteCallbacks final : public BLECharacteristicCallbacks {
public:
  explicit WriteCallbacks(KV4PBleBridgeStream &stream) : _stream(stream) {}

  void onWrite(BLECharacteristic *characteristic) override {
    auto value = characteristic->getValue();
    const uint8_t *bytes = reinterpret_cast<const uint8_t *>(value.c_str());
    _stream.pushReceivedBytes(bytes, value.length());
  }

private:
  KV4PBleBridgeStream &_stream;
};
} // namespace

int KV4PBleBridgeStream::available() {
  portENTER_CRITICAL(&_rxMux);
  const int count = static_cast<int>(rxAvailableUnlocked());
  portEXIT_CRITICAL(&_rxMux);
  return count;
}

int KV4PBleBridgeStream::read() {
  portENTER_CRITICAL(&_rxMux);
  if (rxAvailableUnlocked() == 0) {
    portEXIT_CRITICAL(&_rxMux);
    return -1;
  }
  const uint8_t value = _rx[_tail];
  _tail = (_tail + 1) % RX_BUFFER_SIZE;
  portEXIT_CRITICAL(&_rxMux);
  return value;
}

int KV4PBleBridgeStream::peek() {
  portENTER_CRITICAL(&_rxMux);
  if (rxAvailableUnlocked() == 0) {
    portEXIT_CRITICAL(&_rxMux);
    return -1;
  }
  const uint8_t value = _rx[_tail];
  portEXIT_CRITICAL(&_rxMux);
  return value;
}

void KV4PBleBridgeStream::flush() {
  pumpNotifications();
}

size_t KV4PBleBridgeStream::write(uint8_t byte) {
  return write(&byte, 1);
}

size_t KV4PBleBridgeStream::write(const uint8_t *buffer, size_t size) {
  if (!isReady() || buffer == nullptr || size == 0) {
    return 0;
  }

  for (size_t index = 0; index < size; index++) {
    const size_t nextHead = (_txHead + 1) % TX_BUFFER_SIZE;
    if (nextHead == _txTail) {
      // Emergency guard only: the paced BLE pump should keep this path cold.
      // If it ever happens, prefer newest live audio; KISS resyncs at FEND.
      _txTail = (_txTail + 1) % TX_BUFFER_SIZE;
      _droppedTxBytes++;
    }
    _tx[_txHead] = buffer[index];
    _txHead = (_txHead + 1) % TX_BUFFER_SIZE;
  }

  pumpNotifications();
  return size;
}

void KV4PBleBridgeStream::pumpNotifications() {
  if (!isReady() || _notifyCharacteristic == nullptr) {
    return;
  }

  const uint32_t now = micros();
  if (_lastNotifyMicros != 0 && static_cast<uint32_t>(now - _lastNotifyMicros) < BLE_NOTIFY_MIN_INTERVAL_US) {
    return;
  }

  uint8_t chunk[BLE_NOTIFY_CHUNK];
  const size_t len = dequeueTx(chunk, min(maxNotifyPayload(), sizeof(chunk)));
  if (len == 0) {
    return;
  }

  _notifyCharacteristic->setValue(chunk, len);
  _notifyCharacteristic->notify();
  _lastNotifyMicros = micros();
  esp_task_wdt_reset();
}

size_t KV4PBleBridgeStream::queuedTxBytes() const {
  if (_txHead >= _txTail) {
    return _txHead - _txTail;
  }
  return TX_BUFFER_SIZE - _txTail + _txHead;
}

uint32_t KV4PBleBridgeStream::droppedTxBytes() const {
  return _droppedTxBytes;
}

size_t KV4PBleBridgeStream::txFree() const {
  return TX_BUFFER_SIZE - queuedTxBytes() - 1;
}

size_t KV4PBleBridgeStream::dequeueTx(uint8_t *buffer, size_t maxLen) {
  if (buffer == nullptr || maxLen == 0) {
    return 0;
  }

  size_t count = 0;
  while (count < maxLen && _txTail != _txHead) {
    buffer[count++] = _tx[_txTail];
    _txTail = (_txTail + 1) % TX_BUFFER_SIZE;
  }
  return count;
}

void KV4PBleBridgeStream::clearTx() {
  _txHead = 0;
  _txTail = 0;
  _lastNotifyMicros = 0;
  _droppedTxBytes = 0;
}

size_t KV4PBleBridgeStream::maxNotifyPayload() const {
  size_t payload = _notifyPayloadSize;
  if (payload < 20) {
    payload = 20;
  }
  return payload > BLE_NOTIFY_CHUNK ? BLE_NOTIFY_CHUNK : payload;
}

void KV4PBleBridgeStream::setNotifyCharacteristic(BLECharacteristic *characteristic) {
  _notifyCharacteristic = characteristic;
}

void KV4PBleBridgeStream::setNotifyDescriptor(BLE2902 *descriptor) {
  _notifyDescriptor = descriptor;
}

void KV4PBleBridgeStream::setConnected(bool connected) {
  _connected = connected;
  if (!connected && _notifyDescriptor != nullptr) {
    _notifyDescriptor->setNotifications(false);
    _notifyDescriptor->setIndications(false);
  }
  if (!connected) {
    clearRx();
    clearTx();
  }
}

bool KV4PBleBridgeStream::isConnected() const {
  return _connected;
}

bool KV4PBleBridgeStream::notificationsEnabled() const {
  return _notifyDescriptor != nullptr && _notifyDescriptor->getNotifications();
}

bool KV4PBleBridgeStream::isReady() const {
  return _connected && notificationsEnabled();
}

void KV4PBleBridgeStream::setNotifyPayloadSize(size_t payloadSize) {
  if (payloadSize < 20) {
    _notifyPayloadSize = 20;
  } else if (payloadSize > BLE_NOTIFY_CHUNK) {
    _notifyPayloadSize = BLE_NOTIFY_CHUNK;
  } else {
    _notifyPayloadSize = payloadSize;
  }
}

void KV4PBleBridgeStream::pushReceivedBytes(const uint8_t *data, size_t len) {
  if (data == nullptr || len == 0) {
    return;
  }
  const bool prioritizePttOff = isUrgentPttOffFrame(data, len);
  portENTER_CRITICAL(&_rxMux);
  if (prioritizePttOff) {
    // If PTT-off arrives behind queued TX audio, stale audio must lose. This
    // keeps BLE alive by letting the firmware leave TX before the connection
    // supervision timer expires while old audio frames are being decoded.
    _droppedRxBytes += rxAvailableUnlocked();
    _head = 0;
    _tail = 0;
    kv4pBleUrgentPttOffPending = true;
  }
  for (size_t index = 0; index < len; index++) {
    if (rxFreeUnlocked() == 0) {
      // Preserve the newest bytes, especially an urgent PTT-off frame. KISS
      // resynchronizes at FEND if dropping stale bytes corrupts an old frame.
      _tail = (_tail + 1) % RX_BUFFER_SIZE;
      _droppedRxBytes++;
    }
    const size_t nextHead = (_head + 1) % RX_BUFFER_SIZE;
    _rx[_head] = data[index];
    _head = nextHead;
  }
  portEXIT_CRITICAL(&_rxMux);
}

size_t KV4PBleBridgeStream::rxAvailableUnlocked() const {
  if (_head >= _tail) {
    return _head - _tail;
  }
  return RX_BUFFER_SIZE - _tail + _head;
}

size_t KV4PBleBridgeStream::rxFreeUnlocked() const {
  return RX_BUFFER_SIZE - rxAvailableUnlocked() - 1;
}

uint32_t KV4PBleBridgeStream::droppedRxBytes() const {
  return _droppedRxBytes;
}

void KV4PBleBridgeStream::clearRx() {
  portENTER_CRITICAL(&_rxMux);
  _head = 0;
  _tail = 0;
  _droppedRxBytes = 0;
  portEXIT_CRITICAL(&_rxMux);
}

KV4PBleBridge::KV4PBleBridge(KV4PBleBridgeStream &stream, KV4PBleBridgeStream *aprsTncStream)
  : _stream(stream), _aprsTncStream(aprsTncStream) {}

void KV4PBleBridge::begin(const char *deviceName) {
  BLEDevice::init(deviceName);
  BLEDevice::setMTU(247);
  _server = BLEDevice::createServer();
  _server->setCallbacks(new ServerCallbacks(_stream, _aprsTncStream, *this));

  BLEService *service = _server->createService(KV4P_BLE_SERVICE_UUID);
  _rxCharacteristic = service->createCharacteristic(
    KV4P_BLE_RX_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  _txCharacteristic = service->createCharacteristic(
    KV4P_BLE_TX_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  BLE2902 *notifyDescriptor = new BLE2902();
  _txCharacteristic->addDescriptor(notifyDescriptor);
  _rxCharacteristic->setCallbacks(new WriteCallbacks(_stream));
  _stream.setNotifyCharacteristic(_txCharacteristic);
  _stream.setNotifyDescriptor(notifyDescriptor);

  service->start();

  if (_aprsTncStream != nullptr) {
    BLEService *aprsService = _server->createService(KV4P_APRS_BLE_SERVICE_UUID);
    _aprsRxCharacteristic = aprsService->createCharacteristic(
      KV4P_APRS_BLE_WRITE_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
    );
    _aprsTxCharacteristic = aprsService->createCharacteristic(
      KV4P_APRS_BLE_NOTIFY_UUID,
      BLECharacteristic::PROPERTY_NOTIFY
    );
    BLE2902 *aprsNotifyDescriptor = new BLE2902();
    _aprsTxCharacteristic->addDescriptor(aprsNotifyDescriptor);
    _aprsRxCharacteristic->setCallbacks(new WriteCallbacks(*_aprsTncStream));
    _aprsTncStream->setNotifyCharacteristic(_aprsTxCharacteristic);
    _aprsTncStream->setNotifyDescriptor(aprsNotifyDescriptor);
    aprsService->start();
  }

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  BLEAdvertisementData advertisementData;
  advertisementData.setFlags(ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT);
  advertisementData.setCompleteServices(BLEUUID(KV4P_BLE_SERVICE_UUID));
  BLEAdvertisementData scanResponseData;
  scanResponseData.setName(deviceName);
  if (_aprsTncStream != nullptr) {
    scanResponseData.setCompleteServices(BLEUUID(KV4P_APRS_BLE_SERVICE_UUID));
  }
  advertising->setAdvertisementData(advertisementData);
  advertising->setScanResponseData(scanResponseData);
  // Keep the two 128-bit UUIDs in explicit primary/scan-response packets. The
  // 31-byte BLE advertising limit cannot reliably hold both plus the device
  // name, and addServiceUUID() can make service-filtered discovery flaky.
  advertising->setScanResponse(true);
  advertising->setMinInterval(0x20);
  advertising->setMaxInterval(0x40);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x0c);
  advertising->start();
}

KV4PBleBridgeStream &KV4PBleBridge::stream() {
  return _stream;
}

KV4PBleBridgeStream *KV4PBleBridge::aprsTncStream() {
  return _aprsTncStream;
}

bool KV4PBleBridge::isConnected() const {
  return _stream.isConnected() || hasConnectedClient();
}

bool KV4PBleBridge::isReady() const {
  return _stream.isReady();
}

bool KV4PBleBridge::isAprsTncReady() const {
  return _aprsTncStream != nullptr && _aprsTncStream->isReady();
}

void KV4PBleBridge::requestAdvertisingRestart(uint32_t delayMs, bool allowWhileConnected) {
  _advertisingRestartPending = true;
  _advertisingRestartAllowedWhileConnected = allowWhileConnected;
  _advertisingRestartAtMs = millis() + delayMs;
}

void KV4PBleBridge::cancelAdvertisingRestart() {
  _advertisingRestartPending = false;
  _advertisingRestartAllowedWhileConnected = false;
}

void KV4PBleBridge::noteClientConnected() {
  if (_connectedClients < UINT8_MAX) {
    _connectedClients++;
  }
}

bool KV4PBleBridge::noteClientDisconnected() {
  if (_connectedClients > 0) {
    _connectedClients--;
  }
  return _connectedClients > 0;
}

bool KV4PBleBridge::hasConnectedClient() const {
  return _connectedClients > 0;
}

uint8_t KV4PBleBridge::connectedClientCount() const {
  return _connectedClients;
}

void KV4PBleBridge::restartAdvertising() {
  if (_server != nullptr) {
    _server->startAdvertising();
  }
}

void KV4PBleBridge::loop() {
  _stream.pumpNotifications();
  if (_aprsTncStream != nullptr) {
    const uint32_t now = millis();
    if (_aprsTncStream->isReady() &&
        _aprsTncStream->queuedTxBytes() == 0 &&
        (_lastAprsTncKeepaliveMs == 0 ||
         static_cast<int32_t>(now - _lastAprsTncKeepaliveMs) >= static_cast<int32_t>(APRS_TNC_KEEPALIVE_INTERVAL_MS))) {
      // Some iOS APRS clients leave the KISS TNC idle for long stretches after
      // subscribing. Two FEND bytes are an empty KISS frame, ignored by KISS
      // parsers, but keep peripheral-to-central BLE traffic alive.
      static const uint8_t idleKissFrame[] = {KISS_FEND, KISS_FEND};
      _aprsTncStream->write(idleKissFrame, sizeof(idleKissFrame));
      _lastAprsTncKeepaliveMs = now;
    } else if (!_aprsTncStream->isReady()) {
      _lastAprsTncKeepaliveMs = 0;
    }
    _aprsTncStream->pumpNotifications();
  }
  if (_advertisingRestartPending &&
      (_advertisingRestartAllowedWhileConnected || !hasConnectedClient()) &&
      static_cast<int32_t>(millis() - _advertisingRestartAtMs) >= 0) {
    _advertisingRestartPending = false;
    _advertisingRestartAllowedWhileConnected = false;
    restartAdvertising();
  }
}
