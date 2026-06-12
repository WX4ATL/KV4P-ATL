/*
KV4P/ATL BLE ADPCM audio
Copyright (C) 2026 Blake Ross WX4ATL

SPDX-License-Identifier: GPL-3.0-or-later
*/
#pragma once

#include <Arduino.h>

static constexpr size_t KV4P_ADPCM_FRAME_SAMPLES = 160;
static constexpr size_t KV4P_ADPCM_HEADER_BYTES = 4;
static constexpr size_t KV4P_ADPCM_PAYLOAD_BYTES = 84;
// The SA818/I2S/APRS pipeline remains at the upstream 48 kHz clock. Only the
// BLE voice payload is resampled to compact 8 kHz ADPCM frames.
static constexpr size_t KV4P_ADPCM_CODEC_SAMPLE_RATE = 8000;
static constexpr size_t KV4P_ADPCM_HARDWARE_SAMPLE_RATE = 48000;
static constexpr size_t KV4P_ADPCM_RESAMPLE_RATIO =
    KV4P_ADPCM_HARDWARE_SAMPLE_RATE / KV4P_ADPCM_CODEC_SAMPLE_RATE;
static constexpr size_t KV4P_ADPCM_HARDWARE_FRAME_SAMPLES =
    KV4P_ADPCM_FRAME_SAMPLES * KV4P_ADPCM_RESAMPLE_RATIO;

static constexpr int KV4P_ADPCM_INDEX_TABLE[16] = {
  -1, -1, -1, -1, 2, 4, 6, 8,
  -1, -1, -1, -1, 2, 4, 6, 8
};

static constexpr int KV4P_ADPCM_STEP_TABLE[89] = {
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
  19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
  50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
  130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
  337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
  876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
  2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
  5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
  15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};

class KV4PAdpcmCodec {
public:
  size_t encode(const int16_t *samples, size_t sampleCount, uint8_t *out, size_t maxLen) {
    if (!samples || !out || sampleCount < KV4P_ADPCM_FRAME_SAMPLES || maxLen < KV4P_ADPCM_PAYLOAD_BYTES) {
      return 0;
    }

    int predictor = samples[0];
    int stepIndex = _encoderStepIndex;
    out[0] = static_cast<uint8_t>(static_cast<uint16_t>(samples[0]) & 0xff);
    out[1] = static_cast<uint8_t>((static_cast<uint16_t>(samples[0]) >> 8) & 0xff);
    out[2] = static_cast<uint8_t>(clampIndex(stepIndex));
    out[3] = _sequence++;

    size_t outIndex = KV4P_ADPCM_HEADER_BYTES;
    bool hasLowNibble = false;
    uint8_t lowNibble = 0;
    for (size_t index = 1; index < KV4P_ADPCM_FRAME_SAMPLES; index++) {
      const uint8_t nibble = encodeNibble(samples[index], predictor, stepIndex);
      if (hasLowNibble) {
        out[outIndex++] = lowNibble | static_cast<uint8_t>(nibble << 4);
        hasLowNibble = false;
      } else {
        lowNibble = nibble;
        hasLowNibble = true;
      }
    }
    if (hasLowNibble) {
      out[outIndex++] = lowNibble;
    }

    _encoderStepIndex = clampIndex(stepIndex);
    return outIndex == KV4P_ADPCM_PAYLOAD_BYTES ? outIndex : 0;
  }

  size_t decode(const uint8_t *data, size_t len, int16_t *out, size_t maxSamples) {
    if (!data || !out || len < KV4P_ADPCM_HEADER_BYTES || maxSamples < KV4P_ADPCM_FRAME_SAMPLES) {
      return 0;
    }

    int predictor = static_cast<int16_t>(static_cast<uint16_t>(data[0]) | (static_cast<uint16_t>(data[1]) << 8));
    int stepIndex = clampIndex(data[2]);
    size_t outCount = 0;
    out[outCount++] = clampSample(predictor);

    for (size_t index = KV4P_ADPCM_HEADER_BYTES; index < len && outCount < KV4P_ADPCM_FRAME_SAMPLES; index++) {
      const uint8_t packed = data[index];
      out[outCount++] = decodeNibble(packed & 0x0f, predictor, stepIndex);
      if (outCount < KV4P_ADPCM_FRAME_SAMPLES) {
        out[outCount++] = decodeNibble((packed >> 4) & 0x0f, predictor, stepIndex);
      }
    }
    return outCount == KV4P_ADPCM_FRAME_SAMPLES ? outCount : 0;
  }

  void reset() {
    _encoderStepIndex = 0;
    _sequence = 0;
  }

private:
  int _encoderStepIndex = 0;
  uint8_t _sequence = 0;

  static uint8_t encodeNibble(int16_t sample, int &predictor, int &stepIndex) {
    const int step = KV4P_ADPCM_STEP_TABLE[clampIndex(stepIndex)];
    int diff = static_cast<int>(sample) - predictor;
    int nibble = 0;
    if (diff < 0) {
      nibble = 8;
      diff = -diff;
    }

    int delta = step >> 3;
    if (diff >= step) {
      nibble |= 4;
      diff -= step;
      delta += step;
    }
    if (diff >= (step >> 1)) {
      nibble |= 2;
      diff -= step >> 1;
      delta += step >> 1;
    }
    if (diff >= (step >> 2)) {
      nibble |= 1;
      delta += step >> 2;
    }

    predictor += (nibble & 8) ? -delta : delta;
    predictor = clampPredictor(predictor);
    stepIndex = clampIndex(stepIndex + KV4P_ADPCM_INDEX_TABLE[nibble & 0x0f]);
    return static_cast<uint8_t>(nibble & 0x0f);
  }

  static int16_t decodeNibble(uint8_t nibble, int &predictor, int &stepIndex) {
    const int step = KV4P_ADPCM_STEP_TABLE[clampIndex(stepIndex)];
    int delta = step >> 3;
    if (nibble & 4) delta += step;
    if (nibble & 2) delta += step >> 1;
    if (nibble & 1) delta += step >> 2;
    predictor += (nibble & 8) ? -delta : delta;
    predictor = clampPredictor(predictor);
    stepIndex = clampIndex(stepIndex + KV4P_ADPCM_INDEX_TABLE[nibble & 0x0f]);
    return clampSample(predictor);
  }

  static int clampPredictor(int value) {
    if (value > 32767) return 32767;
    if (value < -32768) return -32768;
    return value;
  }

  static int16_t clampSample(int value) {
    return static_cast<int16_t>(clampPredictor(value));
  }

  static int clampIndex(int value) {
    if (value < 0) return 0;
    if (value > 88) return 88;
    return value;
  }

};
