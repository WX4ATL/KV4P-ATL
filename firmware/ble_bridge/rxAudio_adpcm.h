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
#define APRS_PARALLEL_DEDUP_MS 1000

static uint32_t hashAfskFrame(const uint8_t *frame, size_t len) {
  uint32_t hash = 2166136261u;
  for (size_t index = 0; index < len; index++) {
    hash ^= frame[index];
    hash *= 16777619u;
  }
  return hash;
}

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
        if (encodedLen > 0 && mode == MODE_RX) {
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

static void onAfskPacketDecoded(const uint8_t *frame, size_t len) {
  if (frame && len > 0) {
    static uint32_t lastHash = 0;
    static size_t lastLen = 0;
    static uint32_t lastMs = 0;
    const uint32_t now = millis();
    const uint32_t hash = hashAfskFrame(frame, len);
    if (hash == lastHash && len == lastLen && (uint32_t)(now - lastMs) < APRS_PARALLEL_DEDUP_MS) {
      return;
    }
    lastHash = hash;
    lastLen = len;
    lastMs = now;
    pulseAprsRxLED();
    sendAx25Packet(frame, len);
  }
}

AfskDemodulator afskDemod(AUDIO_SAMPLE_RATE, 2, onAfskPacketDecoded);
AfskDemodulator afskSpaceEmphasisDemod(AUDIO_SAMPLE_RATE, 2, onAfskPacketDecoded);

class Afsk2200PeakFilter {
public:
  Afsk2200PeakFilter(float sampleRate = AUDIO_SAMPLE_RATE, float centerHz = 2200.0f, float q = 1.25f, float gainDb = 9.0f) {
    const float a = powf(10.0f, gainDb / 40.0f);
    const float w0 = 6.283185307179586f * centerHz / sampleRate;
    const float alpha = sinf(w0) / (2.0f * q);
    const float cosw = cosf(w0);
    const float rawB0 = 1.0f + alpha * a;
    const float rawB1 = -2.0f * cosw;
    const float rawB2 = 1.0f - alpha * a;
    const float rawA0 = 1.0f + alpha / a;
    const float rawA1 = -2.0f * cosw;
    const float rawA2 = 1.0f - alpha / a;
    b0 = rawB0 / rawA0;
    b1 = rawB1 / rawA0;
    b2 = rawB2 / rawA0;
    a1 = rawA1 / rawA0;
    a2 = rawA2 / rawA0;
  }

  int16_t process(int16_t input) {
    const float x = (float)input;
    float y = b0 * x + z1;
    z1 = b1 * x - a1 * y + z2;
    z2 = b2 * x - a2 * y;
    if (y > 32767.0f) {
      y = 32767.0f;
    } else if (y < -32768.0f) {
      y = -32768.0f;
    }
    return (int16_t)y;
  }

  void reset() {
    z1 = 0.0f;
    z2 = 0.0f;
  }

private:
  float b0 = 1.0f;
  float b1 = 0.0f;
  float b2 = 0.0f;
  float a1 = 0.0f;
  float a2 = 0.0f;
  float z1 = 0.0f;
  float z2 = 0.0f;
};

class AfskTapEffect : public AudioEffect {
public:
  AfskTapEffect *clone() override {
    return new AfskTapEffect(*this);
  }

  effect_t process(effect_t input) {
    if (active()) {
      samples[sampleCount++] = (int16_t)input;
      if (sampleCount >= AFSK_TAP_BUFFER_SAMPLES) {
        afskDemod.processSamples(samples, sampleCount);
        sampleCount = 0;
      }
    }
    return input;
  }

  void flush() {
    if (sampleCount > 0) {
      afskDemod.processSamples(samples, sampleCount);
      sampleCount = 0;
    }
    afskDemod.flush();
  }

private:
  static const size_t AFSK_TAP_BUFFER_SAMPLES = 256;
  int16_t samples[AFSK_TAP_BUFFER_SAMPLES];
  size_t sampleCount = 0;
};

class AfskSpaceEmphasisTapEffect : public AudioEffect {
public:
  AfskSpaceEmphasisTapEffect *clone() override {
    return new AfskSpaceEmphasisTapEffect(*this);
  }

  effect_t process(effect_t input) {
    if (active()) {
      samples[sampleCount++] = peakFilter.process((int16_t)input);
      if (sampleCount >= AFSK_TAP_BUFFER_SAMPLES) {
        afskSpaceEmphasisDemod.processSamples(samples, sampleCount);
        sampleCount = 0;
      }
    }
    return input;
  }

  void flush() {
    if (sampleCount > 0) {
      afskSpaceEmphasisDemod.processSamples(samples, sampleCount);
      sampleCount = 0;
    }
    afskSpaceEmphasisDemod.flush();
    peakFilter.reset();
  }

private:
  static const size_t AFSK_TAP_BUFFER_SAMPLES = 256;
  Afsk2200PeakFilter peakFilter;
  int16_t samples[AFSK_TAP_BUFFER_SAMPLES];
  size_t sampleCount = 0;
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
AfskSpaceEmphasisTapEffect afskSpaceEmphasisTapEffect;

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
  afskSpaceEmphasisTapEffect.setActive(true);
  afskTapEffect.setActive(true);
  effects.addEffect(dcOffsetRemover);
  // Keep the original post-gain APRS decoder, and add a parallel pre-gain
  // 2200 Hz emphasis path for de-emphasized packet audio that the baseline
  // decoder misses.
  effects.addEffect(afskSpaceEmphasisTapEffect);
  effects.addEffect(gain);
  effects.addEffect(afskTapEffect);
  effects.addEffect(mute);
  effects.begin(rxInfo);
  rxStreamConfigured = true;
}

void endI2SRx() {
  if (rxStreamConfigured) {
    afskSpaceEmphasisTapEffect.flush();
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
    esp_task_wdt_reset();
  }
}
