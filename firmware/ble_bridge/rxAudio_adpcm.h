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
#include <driver/dac.h>
#include <esp_task_wdt.h>
#include <AfskDemodulator.h>
#include "globals.h"
#include "protocol.h"
#include "debug.h"
#include "kv4p_adpcm_audio.h"

#define DECAY_TIME 0.25

extern HostDesiredState desiredState;
extern boolean audioOpen;

struct [[gnu::packed]] AfskDecodeStatsPayload {
  uint32_t audioSamplesSeen;
  uint32_t afskBlocksProcessed;
  uint32_t clipCount;
  uint32_t sampleCount;
  uint16_t rmsLevel;
  uint16_t peakLevel;
  uint16_t afskGainQ8_8;
  uint16_t noiseFloorEstimate;
  uint32_t crcSuccesses;
  uint8_t weakRxActive;
};

class AdpcmAudioOutput : public AudioOutput {
public:
  size_t write(const uint8_t *data, size_t len) override {
    if (!data || len == 0) {
      return len;
    }

    const size_t sampleCount = len / sizeof(int16_t);
    const int16_t *samples = reinterpret_cast<const int16_t *>(data);
    for (size_t index = 0; index < sampleCount; index++) {
      _hardwarePcm[_sampleCount++] = samples[index];
      if (_sampleCount >= KV4P_ADPCM_HARDWARE_FRAME_SAMPLES) {
        downsampleHardwareFrame();
        uint8_t encoded[KV4P_ADPCM_PAYLOAD_BYTES] = {};
        const size_t encodedLen = _codec.encode(_codecPcm, KV4P_ADPCM_FRAME_SAMPLES, encoded, sizeof(encoded));
        _sampleCount = 0;
        if (encodedLen > 0 && mode == MODE_RX && audioOpen) {
          esp_task_wdt_reset();
          sendAudio(encoded, encodedLen);
          esp_task_wdt_reset();
        }
      }
    }
    return len;
  }

  void reset() {
    _sampleCount = 0;
    _codec.reset();
  }

private:
  void downsampleHardwareFrame() {
    for (size_t codecIndex = 0; codecIndex < KV4P_ADPCM_FRAME_SAMPLES; codecIndex++) {
      int32_t sum = 0;
      const size_t sourceOffset = codecIndex * KV4P_ADPCM_RESAMPLE_RATIO;
      for (size_t sub = 0; sub < KV4P_ADPCM_RESAMPLE_RATIO; sub++) {
        sum += _hardwarePcm[sourceOffset + sub];
      }
      _codecPcm[codecIndex] = static_cast<int16_t>(sum / static_cast<int32_t>(KV4P_ADPCM_RESAMPLE_RATIO));
    }
  }

  KV4PAdpcmCodec _codec;
  int16_t _hardwarePcm[KV4P_ADPCM_HARDWARE_FRAME_SAMPLES] = {};
  int16_t _codecPcm[KV4P_ADPCM_FRAME_SAMPLES] = {};
  size_t _sampleCount = 0;
};

class DCOffsetRemover : public AudioEffect {
public:
  DCOffsetRemover(float decay_time = 0.25f, float sample_rate = AUDIO_SAMPLE_RATE): prev_y(0.0f) {
    alpha = 1.0f - expf(-1.0f / (sample_rate * (decay_time / logf(2.0f))));
  }
  DCOffsetRemover(const DCOffsetRemover &) = default;
  effect_t process(effect_t input) {
    return active() ? remove_dc(input) : input;
  }
  DCOffsetRemover *clone() override {
    return new DCOffsetRemover(*this);
  }
private:
  float prev_y;
  float alpha;
  int16_t remove_dc(int16_t x) {
    prev_y = alpha * x + (1.0f - alpha) * prev_y;
    return x - (int16_t)prev_y;
  }
};

void noteAfskCrcSuccess();

static void onAfskPacketDecoded(const uint8_t *frame, size_t len) {
  if (frame && len > 0) {
    noteAfskCrcSuccess();
    pulseAprsRxLED();
    sendAx25Packet(frame, len);
  }
}

AfskDemodulator afskDemod(AUDIO_SAMPLE_RATE, 2, onAfskPacketDecoded);

class AfskTapEffect : public AudioEffect {
public:
  AfskTapEffect() {
    resetBlockStats();
  }

  AfskTapEffect *clone() override {
    return new AfskTapEffect(*this);
  }

  effect_t process(effect_t input) {
    if (active()) {
      samples[sampleCount++] = conditionSample((int16_t)input);
      if (sampleCount >= AFSK_TAP_BUFFER_SAMPLES) {
        afskDemod.processSamples(samples, sampleCount);
        stats.afskBlocksProcessed++;
        updateAgc();
        sampleCount = 0;
      }
    }
    return input;
  }

  void flush() {
    if (sampleCount > 0) {
      afskDemod.processSamples(samples, sampleCount);
      stats.afskBlocksProcessed++;
      updateAgc();
      sampleCount = 0;
    }
    afskDemod.flush();
  }

  void noteCrcSuccess() {
    stats.crcSuccesses++;
  }

  void maybeSendStats() {
    if ((desiredState.flags & HOST_STATE_ENABLE_STATUS_REPORTS) == 0) {
      return;
    }
    const uint32_t now = millis();
    if (now - lastStatsSentMs < AFSK_STATS_INTERVAL_MS) {
      return;
    }
    lastStatsSentMs = now;
    stats.weakRxActive = weakRxActive() ? 1 : 0;
    sendKv4pVendorFrame(COMMAND_AFSK_STATS, reinterpret_cast<const uint8_t *>(&stats), sizeof(stats));
  }

private:
  static const size_t AFSK_TAP_BUFFER_SAMPLES = 256;
  static const uint32_t AFSK_STATS_INTERVAL_MS = 500;
  static constexpr float BASELINE_AFSK_GAIN = 24.0f;
  static constexpr float MIN_AFSK_GAIN = 4.0f;
  static constexpr float MAX_AFSK_GAIN = 48.0f;
  static constexpr float TARGET_RMS = 7000.0f;
  static constexpr float HIGH_RMS = 13000.0f;
  static constexpr int32_t CLIP_LIMIT = 32700;

  bool weakRxActive() const {
    return (desiredState.flags & HOST_STATE_APRS_WEAK_RX) && mode != MODE_TX;
  }

  int16_t conditionSample(int16_t input) {
    const bool weakMode = weakRxActive();
    const float gainToUse = weakMode ? afskGain : BASELINE_AFSK_GAIN;
    float scaled = (float)input * gainToUse;
    if (scaled > CLIP_LIMIT) {
      scaled = CLIP_LIMIT;
      stats.clipCount++;
      blockClips++;
    } else if (scaled < -CLIP_LIMIT) {
      scaled = -CLIP_LIMIT;
      stats.clipCount++;
      blockClips++;
    }

    const int32_t conditioned = (int32_t)lroundf(scaled);
    const uint32_t magnitude = (uint32_t)abs(conditioned);
    blockSumSquares += (double)conditioned * (double)conditioned;
    blockPeak = max(blockPeak, magnitude);
    blockSamples++;
    stats.audioSamplesSeen++;
    stats.sampleCount++;
    return (int16_t)conditioned;
  }

  void updateAgc() {
    if (blockSamples == 0) {
      return;
    }
    const float rms = sqrtf((float)(blockSumSquares / (double)blockSamples));
    stats.rmsLevel = clampU16((uint32_t)lroundf(rms));
    stats.peakLevel = clampU16(blockPeak);
    noiseFloor = (noiseFloor == 0.0f) ? rms : (noiseFloor * 0.96f) + (rms * 0.04f);
    stats.noiseFloorEstimate = clampU16((uint32_t)lroundf(noiseFloor));

    if (weakRxActive()) {
      if (blockClips > 1 || blockPeak > 31000U) {
        afskGain = max(MIN_AFSK_GAIN, afskGain * 0.72f);
      } else if (rms > HIGH_RMS) {
        afskGain = max(MIN_AFSK_GAIN, afskGain * 0.90f);
      } else if (rms < TARGET_RMS && blockPeak < 26000U) {
        afskGain = min(MAX_AFSK_GAIN, afskGain * 1.03f);
      }
    } else {
      afskGain = BASELINE_AFSK_GAIN;
    }
    stats.afskGainQ8_8 = clampU16((uint32_t)lroundf(afskGain * 256.0f));
    resetBlockStats();
  }

  uint16_t clampU16(uint32_t value) const {
    return value > 65535U ? 65535U : (uint16_t)value;
  }

  void resetBlockStats() {
    blockSumSquares = 0.0;
    blockPeak = 0;
    blockSamples = 0;
    blockClips = 0;
  }

  int16_t samples[AFSK_TAP_BUFFER_SAMPLES];
  size_t sampleCount = 0;
  AfskDecodeStatsPayload stats = {};
  float afskGain = BASELINE_AFSK_GAIN;
  float noiseFloor = 0.0f;
  double blockSumSquares = 0.0;
  uint32_t blockPeak = 0;
  uint32_t blockSamples = 0;
  uint32_t blockClips = 0;
  uint32_t lastStatsSentMs = 0;
};

bool rxStreamConfigured = false;
AnalogAudioStream in;
AudioInfo rxInfo(AUDIO_SAMPLE_RATE, 1, 16);
AdpcmAudioOutput rxAdpcmOutput;
AudioEffectStream effects(in);
StreamCopy rxCopier(rxAdpcmOutput, effects);
Boost mute(0.0);
Boost gain(24.0);
DCOffsetRemover dcOffsetRemover(DECAY_TIME, AUDIO_SAMPLE_RATE);
AfskTapEffect afskTapEffect;

void noteAfskCrcSuccess() {
  afskTapEffect.noteCrcSuccess();
}

inline void injectADCBias() {
  dac_output_enable(DAC_CHANNEL_2);
  dac_output_voltage(DAC_CHANNEL_2, (255.0 / 3.3) * hw.adcBias);
}

inline void setUpADCAttenuator() {
  adc1_config_channel_atten(I2S_ADC_CHANNEL, hw.adcAttenuation);
}

void initI2SRx() {
  if (rxStreamConfigured) {
    return;
  }
  injectADCBias();
  setUpADCAttenuator();
  auto config = in.defaultConfig(RX_MODE);
  config.copyFrom(rxInfo);
  config.is_auto_center_read = false;
  config.use_apll = true;
  config.auto_clear = false;
  config.adc_pin = hw.pins.pinAudioIn;
  config.sample_rate = AUDIO_SAMPLE_RATE * 1.02;
  in.begin(config);
  effects.clear();
  rxAdpcmOutput.reset();
  afskTapEffect.setActive(true);
  effects.addEffect(dcOffsetRemover);
  effects.addEffect(afskTapEffect);
  effects.addEffect(gain);
  effects.addEffect(mute);
  effects.begin(rxInfo);
  rxStreamConfigured = true;
}

void endI2SRx() {
  if (rxStreamConfigured) {
    afskTapEffect.flush();
    effects.end();
    in.end();
  }
  rxAdpcmOutput.reset();
  rxStreamConfigured = false;
}

void rxAudioLoop() {
  if ((mode == MODE_RX || mode == MODE_STOPPED) && rxStreamConfigured) {
    mute.setActive(squelched);
    rxCopier.copy();
    afskTapEffect.maybeSendStats();
    esp_task_wdt_reset();
  }
}
