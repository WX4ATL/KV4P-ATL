/*
KV4P-HT (see http://kv4p.com)
Copyright (C) 2025 Vance Vagell
Copyright (C) 2026 Blake Ross WX4ATL

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

SPDX-License-Identifier: GPL-3.0-or-later
*/
#pragma once

#include <Arduino.h>
#include <AudioTools.h>
#include <esp_task_wdt.h>
#include <AfskModulator.h>
#include "globals.h"
#include "protocol.h"
#include "kv4p_adpcm_audio.h"

extern volatile bool kv4pBleUrgentPttOffPending;

bool txStreamConfigured = false;
I2SStream out;
AudioInfo txInfo(AUDIO_SAMPLE_RATE, 1, 16);
KV4PAdpcmCodec txAdpcmCodec;
int16_t txAdpcmCodecPcm[KV4P_ADPCM_FRAME_SAMPLES] = {};
int16_t txAdpcmHardwarePcm[KV4P_ADPCM_HARDWARE_FRAME_SAMPLES] = {};

uint32_t txStartTime = -1;
const uint16_t RUNAWAY_TX_SEC = 200;

float txAfskBlock[TX_AFSK_BLOCK_SAMPLES];
int16_t txAfskPcm[TX_AFSK_BLOCK_SAMPLES];

static void onAfskTxSamples(const float *samples, size_t count) {
  if (!samples || count == 0 || !txStreamConfigured) {
    return;
  }
  if (count > TX_AFSK_BLOCK_SAMPLES) {
    count = TX_AFSK_BLOCK_SAMPLES;
  }
  for (size_t i = 0; i < count; i++) {
    float s = samples[i] * TX_AFSK_GAIN;
    if (s > 1.0f) s = 1.0f;
    if (s < -1.0f) s = -1.0f;
    txAfskPcm[i] = (int16_t)lroundf(s * 32767.0f);
  }
  out.write((uint8_t *)txAfskPcm, count * sizeof(int16_t));
  esp_task_wdt_reset();
}

AfskModulator afskMod(AUDIO_SAMPLE_RATE, onAfskTxSamples);

void initI2STx() {
  auto config = out.defaultConfig(TX_MODE);
  config.copyFrom(txInfo);
  config.pin_data = hw.pins.pinAudioOut;
  config.pin_ws = 27;
  config.use_apll = true;
  config.auto_clear = false;
  config.signal_type = PDM;
  out.begin(config);
  txAdpcmCodec.reset();
  i2s_zero_dma_buffer(I2S_NUM_0);
  txStreamConfigured = true;
}

void endI2STx() {
  if (txStreamConfigured) {
    pinMode(hw.pins.pinAudioOut, INPUT);
    out.end();
  }
  txStreamConfigured = false;
  txAdpcmCodec.reset();
}

void processTxAudio(uint8_t *src, size_t len) {
  if (!src || len == 0 || !txStreamConfigured || kv4pBleUrgentPttOffPending) {
    return;
  }
  const size_t decodedSamples = txAdpcmCodec.decode(src, len, txAdpcmCodecPcm, KV4P_ADPCM_FRAME_SAMPLES);
  if (decodedSamples != KV4P_ADPCM_FRAME_SAMPLES || kv4pBleUrgentPttOffPending) {
    return;
  }
  for (size_t codecIndex = 0; codecIndex < KV4P_ADPCM_FRAME_SAMPLES; codecIndex++) {
    const int32_t current = txAdpcmCodecPcm[codecIndex];
    const size_t nextIndex = (codecIndex + 1 < KV4P_ADPCM_FRAME_SAMPLES) ? codecIndex + 1 : codecIndex;
    const int32_t next = txAdpcmCodecPcm[nextIndex];
    for (size_t sub = 0; sub < KV4P_ADPCM_RESAMPLE_RATIO; sub++) {
      const int32_t interpolated =
          current + ((next - current) * static_cast<int32_t>(sub)) / static_cast<int32_t>(KV4P_ADPCM_RESAMPLE_RATIO);
      txAdpcmHardwarePcm[(codecIndex * KV4P_ADPCM_RESAMPLE_RATIO) + sub] = static_cast<int16_t>(interpolated);
    }
  }
  const uint8_t *bytes = reinterpret_cast<const uint8_t *>(txAdpcmHardwarePcm);
  size_t totalWritten = 0;
  const size_t byteCount = KV4P_ADPCM_HARDWARE_FRAME_SAMPLES * sizeof(int16_t);
  uint8_t zeroWriteCount = 0;
  while (totalWritten < byteCount && !kv4pBleUrgentPttOffPending) {
    const size_t written = out.write(bytes + totalWritten, byteCount - totalWritten);
    if (written == 0) {
      if (++zeroWriteCount >= 3) {
        break;
      }
      delay(1);
    } else {
      totalWritten += written;
      zeroWriteCount = 0;
    }
    esp_task_wdt_reset();
  }
}

void processTxAx25(uint8_t *src, size_t len) {
  if (!src || len == 0) {
    return;
  }
  afskMod.modulate(src, len, txAfskBlock, TX_AFSK_BLOCK_SAMPLES, TX_AFSK_LEAD_SILENCE_MS, TX_AFSK_TAIL_SILENCE_MS);
}

void inline txAudioLoop() {
  if (mode == MODE_TX) {
    if ((millis() - txStartTime) > RUNAWAY_TX_SEC * 1000) {
      setMode(rxIdleMode());
      esp_task_wdt_reset();
    }
  }
}
