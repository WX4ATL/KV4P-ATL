/*
KV4P/ATL BLE bridge
Copyright (C) 2026 Blake Ross WX4ATL

This file is intended to be used with the GPL-3.0-or-later KV4P HT
firmware. It preserves the existing KV4P KISS protocol and only adds a
Nordic UART-compatible BLE byte transport for KV4P/ATL.

SPDX-License-Identifier: GPL-3.0-or-later
*/
#pragma once

#include <Arduino.h>
#include <BLEAdvertising.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

static const char *KV4P_BLE_SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
static const char *KV4P_BLE_RX_UUID      = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
static const char *KV4P_BLE_TX_UUID      = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

// Standard BLE KISS TNC service used by aprs.fi, PocketPacket-compatible
// Bluetooth TNC support, Mobilinkd-style clients, and RadioMail. The naming
// below follows this bridge's internal direction: host writes to WRITE_UUID,
// and the radio notifies host RX KISS bytes on NOTIFY_UUID.
static const char *KV4P_APRS_BLE_SERVICE_UUID = "00000001-BA2A-46C9-AE49-01B0961F68BB";
static const char *KV4P_APRS_BLE_WRITE_UUID   = "00000002-BA2A-46C9-AE49-01B0961F68BB";
static const char *KV4P_APRS_BLE_NOTIFY_UUID  = "00000003-BA2A-46C9-AE49-01B0961F68BB";

// Stream facade so the upstream KissParser and sendKissFrame(Stream&, ...)
// helpers can be reused for BLE exactly as they are reused for USB Serial.
class KV4PBleBridgeStream final : public Stream {
public:
  static constexpr size_t RX_BUFFER_SIZE = 4096;
  static constexpr size_t TX_BUFFER_SIZE = 8192;
  static constexpr size_t BLE_NOTIFY_CHUNK = 244;
  static constexpr uint32_t BLE_NOTIFY_MIN_INTERVAL_US = 1500;

  int available() override;
  int read() override;
  int peek() override;
  void flush() override;
  size_t write(uint8_t byte) override;
  size_t write(const uint8_t *buffer, size_t size) override;

  void setNotifyCharacteristic(BLECharacteristic *characteristic);
  void setNotifyDescriptor(BLE2902 *descriptor);
  void setConnected(bool connected);
  bool isConnected() const;
  bool notificationsEnabled() const;
  bool isReady() const;
  void setNotifyPayloadSize(size_t payloadSize);
  void pumpNotifications();
  void pushReceivedBytes(const uint8_t *data, size_t len);
  uint32_t droppedTxBytes() const;
  uint32_t droppedRxBytes() const;
  size_t queuedTxBytes() const;

private:
  size_t rxAvailableUnlocked() const;
  size_t rxFreeUnlocked() const;
  size_t maxNotifyPayload() const;
  size_t txFree() const;
  size_t dequeueTx(uint8_t *buffer, size_t maxLen);
  void clearRx();
  void clearTx();

  BLECharacteristic *_notifyCharacteristic = nullptr;
  BLE2902 *_notifyDescriptor = nullptr;
  volatile bool _connected = false;
  portMUX_TYPE _rxMux = portMUX_INITIALIZER_UNLOCKED;
  uint8_t _rx[RX_BUFFER_SIZE] = {};
  volatile size_t _head = 0;
  volatile size_t _tail = 0;
  uint8_t _tx[TX_BUFFER_SIZE] = {};
  volatile size_t _txHead = 0;
  volatile size_t _txTail = 0;
  volatile size_t _notifyPayloadSize = 20;
  uint32_t _lastNotifyMicros = 0;
  uint32_t _droppedTxBytes = 0;
  volatile uint32_t _droppedRxBytes = 0;
};

class KV4PBleBridge final {
public:
  explicit KV4PBleBridge(KV4PBleBridgeStream &stream, KV4PBleBridgeStream *aprsTncStream = nullptr);

  void begin(const char *deviceName = "KV4P HT BLE");
  KV4PBleBridgeStream &stream();
  KV4PBleBridgeStream *aprsTncStream();
  bool isConnected() const;
  bool isReady() const;
  bool isAprsTncReady() const;
  void loop();
  void requestAdvertisingRestart(uint32_t delayMs = 500);
  void cancelAdvertisingRestart();

private:
  KV4PBleBridgeStream &_stream;
  KV4PBleBridgeStream *_aprsTncStream = nullptr;
  BLEServer *_server = nullptr;
  BLECharacteristic *_rxCharacteristic = nullptr;
  BLECharacteristic *_txCharacteristic = nullptr;
  BLECharacteristic *_aprsRxCharacteristic = nullptr;
  BLECharacteristic *_aprsTxCharacteristic = nullptr;
  volatile bool _advertisingRestartPending = false;
  uint32_t _advertisingRestartAtMs = 0;
  void restartAdvertising();
};
