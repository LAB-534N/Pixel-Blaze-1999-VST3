#pragma once

#include <atomic>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <mutex>
#include <vector>

namespace PixelBlaze {

// Exact NES 2A03 32-step 4-bit Triangle sequence (15..0..15)
static constexpr uint8_t kNesTriangleTable[32] = {
    15, 14, 13, 12, 11, 10,  9,  8,  7,  6,  5,  4,  3,  2,  1,  0,
     0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15
};

enum PixelParamID : uint32_t {
    kParamChipMode = 0,       // 0.0=NES 2A03, 0.333=GameBoy DMG, 0.667=C64 SID 6581, 1.0=Sega SN76489
    kParamPulseDuty = 1,      // 0..1 (12.5%, 25%, 50%, 75% or continuous PWM in SID mode)
    kParamSubWaveLevel = 2,   // 0..1 (NES Triangle / DMG 4-Bit Wavetable / SID Saw+Tri / SMS Square 2+3)
    kParamNoiseLevel = 3,     // 0..1 (LFSR Noise & Percussion Transient layer level)
    kParamNoiseMode = 4,      // 0.0=White LFSR, 0.5=Metallic 93-Step LFSR, 1.0=8-Bit Drum Transient
    kParamPitchSweep = 5,     // 0..1 (0.5 = neutral; <0.5 downward laser/kick sweep; >0.5 upward jump/1-up sweep)
    kParamGlideTime = 6,      // 0..1 (Portamento / glide speed)
    kParamVibratoRate = 7,    // 0..1 (1 Hz .. 16 Hz stepped 60Hz LFO)
    kParamVibratoDepth = 8,   // 0..1 (0 .. 2.5 semitones)

    kParamEnvAttack = 9,      // 0..1 (1 ms .. 1500 ms)
    kParamEnvDecay = 10,      // 0..1 (10 ms .. 2500 ms)
    kParamEnvSustain = 11,    // 0..1 (0..100% 4-bit quantized sustain)
    kParamEnvRelease = 12,    // 0..1 (5 ms .. 2500 ms)

    kParamArpEnable = 13,     // 0 or 1 (Tracker Arpeggiator ON/OFF)
    kParamArpPattern = 14,    // 0=Chord Up, 0.2=Chord Down, 0.4=Octave, 0.6=Mega 3-Oct, 0.8=1-Up Coin, 1.0=Custom 8-Step Grid
    kParamArpSpeed = 15,      // 0..1 (10 Hz .. 60 Hz NTSC / 50 Hz PAL tracker tick speed)

    kParamDacBits = 16,       // 0..1 (4-bit stair-step DAC .. 12-bit clean)
    kParamSampleRateCrush = 17,// 0..1 (0 = pure 44.1kHz, 1 = extreme 4kHz aliasing)
    kParamFilterCutoff = 18,  // 0..1 (SID 6581 Resonant Filter Cutoff: 80 Hz .. 18 kHz)
    kParamFilterReso = 19,    // 0..1 (SID 6581 Filter Resonance: 0 .. 92%)
    kParamFilterType = 20,    // 0.0=Lowpass, 0.5=Bandpass, 1.0=Highpass

    kParamEchoTime = 21,      // 0..1 (40 ms .. 480 ms tracker echo delay)
    kParamEchoFeedback = 22,  // 0..1 (0 .. 85% feedback)
    kParamEchoMix = 23,       // 0..1 (0 .. 100% wet mix)

    kParamMonoMode = 24,      // 0 = 12-Voice Polyphonic, 1 = Mono Chiptune Lead
    kParamConsoleSkin = 25,   // 0.0=NES 1985, 0.333=Famicom 83, 0.667=GameBoy DMG, 1.0=C64 Breadbin
    kParamMasterVolume = 26,  // 0..1

    // MIDI Controller mirrors
    kParamPitchBend = 27,     // 0..1 (0.5 center, +/- 12 semitones in chiptune mode or +/- 2)
    kParamModWheel = 28,      // 0..1
    kParamSustainPedal = 29,  // 0..1

    kNumParams = 30
};

struct ParamMetadata {
    uint32_t id;
    const char* title;
    const char* shortTitle;
    const char* units;
    float defaultNorm;
    int32_t stepCount; // 0 = continuous, 1 = toggle, >1 = discrete steps
};

static constexpr ParamMetadata kParamInfo[kNumParams] = {
    {kParamChipMode,        "Sound Chip Engine",   "Chip",     "",    0.00f, 3},
    {kParamPulseDuty,       "Pulse Duty / PWM",    "Duty",     "%",   0.34f, 0},
    {kParamSubWaveLevel,    "Tri / Wave RAM Mix",  "WaveMix",  "%",   0.70f, 0},
    {kParamNoiseLevel,      "LFSR Noise / Drum",   "Noise",    "%",   0.18f, 0},
    {kParamNoiseMode,       "Noise / Drum Mode",   "NsMode",   "",    0.00f, 2},
    {kParamPitchSweep,      "Hardware Pitch Sweep","Sweep",    "%",   0.50f, 0},
    {kParamGlideTime,       "Portamento Glide",    "Glide",    "ms",  0.12f, 0},
    {kParamVibratoRate,     "60Hz Vibrato Rate",   "VibRate",  "Hz",  0.48f, 0},
    {kParamVibratoDepth,    "Vibrato Depth",       "VibDep",   "%",   0.15f, 0},

    {kParamEnvAttack,       "Envelope Attack",     "Attack",   "ms",  0.01f, 0},
    {kParamEnvDecay,        "Envelope Decay",      "Decay",    "ms",  0.35f, 0},
    {kParamEnvSustain,      "Envelope Sustain",    "Sustain",  "%",   0.65f, 0},
    {kParamEnvRelease,      "Envelope Release",    "Release",  "ms",  0.18f, 0},

    {kParamArpEnable,       "Tracker Arp Enable",  "ArpOn",    "",    0.00f, 1},
    {kParamArpPattern,      "Tracker Arp Mode",    "ArpMode",  "",    0.00f, 5},
    {kParamArpSpeed,        "Arp Tick Rate",       "ArpSpd",   "Hz",  0.82f, 0},

    {kParamDacBits,         "DAC Bit Quantizer",   "DACBits",  "bit", 0.15f, 0},
    {kParamSampleRateCrush, "Alias Decimator",     "Decim",    "%",   0.12f, 0},
    {kParamFilterCutoff,    "SID Filter Cutoff",   "Cutoff",   "Hz",  0.85f, 0},
    {kParamFilterReso,      "SID Filter Reso",     "Reso",     "%",   0.20f, 0},
    {kParamFilterType,      "SID Filter Mode",     "FltMode",  "",    0.00f, 2},

    {kParamEchoTime,        "Tracker Echo Time",   "EchoTm",   "ms",  0.38f, 0},
    {kParamEchoFeedback,    "Tracker Echo Regen",  "EchoFB",   "%",   0.35f, 0},
    {kParamEchoMix,         "Tracker Echo Mix",    "EchoMix",  "%",   0.22f, 0},

    {kParamMonoMode,        "Mono Chiptune Mode",  "Mono",     "",    0.00f, 1},
    {kParamConsoleSkin,     "Console Shell Skin",  "Skin",     "",    0.00f, 3},
    {kParamMasterVolume,    "Master Output",       "Master",   "dB",  0.82f, 0},

    {kParamPitchBend,       "Pitch Bend",          "Bend",     "st",  0.50f, 0},
    {kParamModWheel,        "Mod Wheel",           "Mod",      "%",   0.00f, 0},
    {kParamSustainPedal,    "Sustain Pedal",       "SustainP", "",    0.00f, 1}
};

struct CartridgePreset {
    const char* code;        // e.g. "PAK-01"
    const char* name;        // e.g. "MEGA BLASTER LEAD"
    const char* category;    // e.g. "NES 2A03 LEAD"
    uint32_t cartColorHex;   // Cartridge shell accent color
    float values[kNumParams];
    uint8_t waveRam[32];     // 32 steps of 4-bit (0..15) custom wavetable
    int8_t arpSteps[8];      // 8 steps of tracker semitone offsets (-12..+24)
};

static constexpr int kNumPresets = 12;

static const CartridgePreset kFactoryPresets[kNumPresets] = {
    // 0: PAK-01 Mega Blaster Lead (Classic NES 25% Pulse + Triangle Sub + Echo)
    {
        "PAK-01", "MEGA BLASTER LEAD", "NES 2A03 LEAD", 0xE62E2D,
        {
            0.00f, 0.34f, 0.72f, 0.16f, 1.00f, 0.50f, 0.10f, 0.52f, 0.22f,
            0.01f, 0.38f, 0.72f, 0.16f,
            0.00f, 0.00f, 0.85f,
            0.12f, 0.10f, 0.90f, 0.15f, 0.00f,
            0.36f, 0.35f, 0.25f,
            0.00f, 0.00f, 0.84f, 0.50f, 0.00f, 0.00f
        },
        {0,2,4,6,8,10,12,14,15,14,12,10,8,6,4,2, 0,2,5,9,12,15,12,9,6,4,3,2,1,0,0,0},
        {0, 4, 7, 12, 7, 4, 0, 12}
    },
    // 1: PAK-02 Sunsoft Triangle Bass (Punchy NES Non-Linear Triangle + Pitch-Drop DPCM Kick Transient)
    {
        "PAK-02", "SUNSOFT TRI BASS", "NES 2A03 BASS", 0x2979FF,
        {
            0.00f, 0.15f, 1.00f, 0.42f, 1.00f, 0.34f, 0.06f, 0.35f, 0.05f,
            0.00f, 0.28f, 0.45f, 0.10f,
            0.00f, 0.40f, 0.82f,
            0.05f, 0.18f, 0.68f, 0.30f, 0.00f,
            0.25f, 0.15f, 0.06f,
            1.00f, 0.00f, 0.88f, 0.50f, 0.00f, 0.00f
        },
        {0,1,3,5,7,9,11,13,15,15,13,11,9,7,5,3, 1,0,0,2,5,8,12,15,12,8,4,2,1,0,0,0},
        {0, 12, 0, 12, 0, 7, 10, 12}
    },
    // 2: PAK-03 Starlight 60Hz Arp (Fast NTSC 60Hz Tracker Chord Arpeggiator)
    {
        "PAK-03", "STARLIGHT 60HZ ARP", "NES / TRACKER ARP", 0x00E676,
        {
            0.00f, 0.12f, 0.65f, 0.12f, 0.00f, 0.50f, 0.02f, 0.55f, 0.12f,
            0.00f, 0.42f, 0.68f, 0.22f,
            1.00f, 0.00f, 0.90f,
            0.10f, 0.08f, 0.92f, 0.18f, 0.00f,
            0.42f, 0.45f, 0.34f,
            0.00f, 0.00f, 0.82f, 0.50f, 0.00f, 0.00f
        },
        {15,15,14,12,10,8,6,4,2,0,0,2,4,6,8,10, 12,14,15,13,11,9,7,5,3,1,0,2,5,8,11,14},
        {0, 4, 7, 12, 16, 12, 7, 4}
    },
    // 3: PAK-04 Pocket DMG Wave (Game Boy DMG-01 32-Step 4-Bit Wavetable + Dual Pulse)
    {
        "PAK-04", "POCKET DMG WAVE", "GAME BOY DMG-01", 0x8BC34A,
        {
            0.333f, 0.66f, 0.92f, 0.14f, 0.00f, 0.50f, 0.08f, 0.48f, 0.18f,
            0.01f, 0.45f, 0.75f, 0.20f,
            0.00f, 1.00f, 0.78f,
            0.00f, 0.22f, 0.86f, 0.22f, 0.00f,
            0.32f, 0.32f, 0.22f,
            0.00f, 0.667f, 0.84f, 0.50f, 0.00f, 0.00f
        },
        {15,15,15,12,8,4,12,15, 15,11,4,0,0,4,11,15, 14,10,3,0,2,7,13,15, 12,8,4,1,0,0,3,9},
        {0, 7, 12, 7, 0, 3, 7, 10}
    },
    // 4: PAK-05 Robocop SID 6581 (Commodore 64 PWM + Saw + Resonant 6581 Filter)
    {
        "PAK-05", "ROBOCOP SID 6581", "C64 MOS 6581 SID", 0xFFA000,
        {
            0.667f, 0.58f, 0.85f, 0.08f, 0.50f, 0.50f, 0.16f, 0.44f, 0.24f,
            0.03f, 0.52f, 0.70f, 0.28f,
            0.00f, 0.60f, 0.76f,
            0.35f, 0.08f, 0.56f, 0.68f, 0.00f,
            0.44f, 0.42f, 0.30f,
            0.00f, 1.00f, 0.84f, 0.50f, 0.00f, 0.00f
        },
        {15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0, 15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0},
        {0, 12, 24, 12, 0, 7, 12, 19}
    },
    // 5: PAK-06 Master System Poly (Sega SN76489 3x Detuned Square Chorus + Periodic Noise)
    {
        "PAK-06", "MASTER SYSTEM POLY", "SEGA SN76489 PSG", 0x00B0FF,
        {
            1.00f, 0.50f, 0.88f, 0.15f, 0.50f, 0.50f, 0.05f, 0.42f, 0.16f,
            0.02f, 0.48f, 0.78f, 0.26f,
            0.00f, 0.00f, 0.75f,
            0.12f, 0.12f, 0.88f, 0.15f, 0.00f,
            0.38f, 0.36f, 0.26f,
            0.00f, 0.00f, 0.82f, 0.50f, 0.00f, 0.00f
        },
        {15,15,15,15,15,15,15,15, 0,0,0,0,0,0,0,0, 12,12,12,12,3,3,3,3, 15,15,0,0,15,15,0,0},
        {0, 4, 7, 11, 12, 11, 7, 4}
    },
    // 6: PAK-07 Famicom Disk Bell (Famicom 1983 Gold Skin + FM/Wavetable Chime)
    {
        "PAK-07", "FAMICOM DISK BELL", "FAMICOM 2A03+WAVE", 0xD500F9,
        {
            0.333f, 0.12f, 0.95f, 0.06f, 0.50f, 0.50f, 0.00f, 0.56f, 0.14f,
            0.00f, 0.50f, 0.25f, 0.42f,
            0.00f, 0.20f, 0.84f,
            0.08f, 0.16f, 0.84f, 0.25f, 0.00f,
            0.46f, 0.48f, 0.35f,
            0.00f, 0.333f, 0.84f, 0.50f, 0.00f, 0.00f
        },
        {8,13,15,12,6,2,5,11, 14,11,5,1,3,9,13,10, 5,1,2,8,12,9,3,0, 4,10,13,9,4,1,3,7},
        {0, 7, 12, 19, 24, 19, 12, 7}
    },
    // 7: PAK-08 Metroid Brinstar Pad (Dark Atmospheric Chiptune Pad + Filter + Echo)
    {
        "PAK-08", "BRINSTAR DEPTHS PAD", "8-BIT ATMOSPHERE", 0x651FFF,
        {
            0.667f, 0.42f, 0.82f, 0.12f, 0.50f, 0.50f, 0.22f, 0.38f, 0.28f,
            0.28f, 0.62f, 0.82f, 0.48f,
            0.00f, 0.00f, 0.65f,
            0.22f, 0.18f, 0.52f, 0.54f, 0.00f,
            0.52f, 0.55f, 0.42f,
            0.00f, 0.333f, 0.84f, 0.50f, 0.00f, 0.00f
        },
        {7,10,13,15,14,11,8,5, 3,2,4,8,12,14,12,8, 4,1,0,2,6,10,12,10, 6,2,0,1,3,5,6,7},
        {0, 3, 7, 10, 12, 10, 7, 3}
    },
    // 8: PAK-09 1-Up Coin & Powerup (Authentic Arcade/NES Coin & Powerup SFX Arp)
    {
        "PAK-09", "1-UP COIN & POWERUP", "8-BIT SFX / ARP", 0xFFD600,
        {
            0.00f, 0.34f, 0.50f, 0.05f, 0.00f, 0.68f, 0.00f, 0.50f, 0.00f,
            0.00f, 0.32f, 0.40f, 0.22f,
            1.00f, 0.80f, 0.88f,
            0.00f, 0.05f, 0.95f, 0.10f, 0.00f,
            0.30f, 0.28f, 0.20f,
            1.00f, 0.00f, 0.85f, 0.50f, 0.00f, 0.00f
        },
        {15,15,15,15,0,0,0,0, 15,15,15,15,15,15,15,15, 0,0,0,0,0,0,0,0, 15,15,15,15,0,0,0,0},
        {0, 5, 5, 5, 5, 5, 5, 5}
    },
    // 9: PAK-10 Laser & Jump Blaster (Hardware Pitch-Sweep Unit + Metallic 93-Step LFSR)
    {
        "PAK-10", "LASER & JUMP BLASTER", "8-BIT ARCADE SFX", 0xFF3D00,
        {
            0.00f, 0.12f, 0.40f, 0.48f, 0.50f, 0.12f, 0.00f, 0.75f, 0.35f,
            0.00f, 0.30f, 0.15f, 0.14f,
            0.00f, 0.60f, 0.92f,
            0.00f, 0.25f, 0.82f, 0.45f, 0.00f,
            0.24f, 0.35f, 0.24f,
            1.00f, 0.00f, 0.85f, 0.50f, 0.00f, 0.00f
        },
        {15,0,15,0,14,1,13,2, 12,3,11,4,10,5,9,6, 8,7,15,0,12,3,9,6, 15,15,0,0,15,0,15,0},
        {12, 9, 6, 3, 0, -3, -6, -12}
    },
    // 10: PAK-11 Boss Explosion Noise (15-Bit LFSR Noise + 4-Bit DAC Rumble)
    {
        "PAK-11", "BOSS EXPLOSION SFX", "15-BIT LFSR NOISE", 0xFF1744,
        {
            0.00f, 0.50f, 0.35f, 1.00f, 0.00f, 0.08f, 0.00f, 0.25f, 0.45f,
            0.00f, 0.68f, 0.20f, 0.55f,
            0.00f, 0.00f, 0.50f,
            0.00f, 0.62f, 0.44f, 0.52f, 0.00f,
            0.48f, 0.46f, 0.32f,
            0.00f, 0.00f, 0.88f, 0.50f, 0.00f, 0.00f
        },
        {15,2,13,0,9,14,3,11, 1,15,6,12,0,8,14,4, 11,2,15,7,1,13,5,10, 0,14,3,9,15,4,8,1},
        {0, -2, -5, -7, -9, -12, -12, -12}
    },
    // 11: PAK-12 Pixel-Blaze 1999 Anthem (Custom 8-Step Tracker Grid + 4-Bit Wave + Pulse)
    {
        "PAK-12", "PIXEL-BLAZE 1999", "CUSTOM TRACKER ARP", 0x00E5FF,
        {
            0.333f, 0.34f, 0.84f, 0.22f, 1.00f, 0.50f, 0.05f, 0.50f, 0.16f,
            0.00f, 0.40f, 0.72f, 0.20f,
            1.00f, 1.00f, 0.80f,
            0.08f, 0.14f, 0.86f, 0.28f, 0.00f,
            0.36f, 0.40f, 0.28f,
            0.00f, 0.00f, 0.86f, 0.50f, 0.00f, 0.00f
        },
        {15,15,12,12,8,8,14,14, 15,11,7,3,0,0,4,8, 12,15,12,8,4,0,3,7, 11,14,10,6,2,0,5,10},
        {0, 12, 7, 12, 15, 12, 7, 10}
    }
};

struct UiNoteEvent {
    int16_t pitch;
    float velocity;
    bool isNoteOn;
};

struct SharedSynthBridge {
    std::atomic<float> params[kNumParams];
    std::atomic<int> currentPreset{0};

    // Custom 32-step 4-bit Wavetable RAM (values 0..15)
    std::atomic<uint8_t> waveRam[32];

    // Custom 8-step Tracker Arpeggiator Semitone Offsets (-12..+24) & Duty per step (0..3)
    std::atomic<int8_t> arpSteps[8];
    std::atomic<uint8_t> arpDutySteps[8];
    std::atomic<int> activeArpStep{0};

    // UI -> Audio lock-free note ring buffer (for on-screen piano, A-button fire, QWERTY keys)
    static constexpr int kQueueSize = 128;
    UiNoteEvent uiNoteQueue[kQueueSize];
    std::atomic<uint32_t> uiWriteIdx{0};
    std::atomic<uint32_t> uiReadIdx{0};

    // Audio -> UI feedback for keyboard highlight, CRT oscilloscope, and meters
    std::atomic<uint64_t> activeKeyMaskLo{0}; // MIDI notes 0..63
    std::atomic<uint64_t> activeKeyMaskHi{0}; // MIDI notes 64..127
    std::atomic<int> activeVoiceCount{0};
    std::atomic<float> meterPeakL{0.0f};
    std::atomic<float> meterPeakR{0.0f};

    // D-Pad interactive state (-1.0 .. +1.0)
    std::atomic<float> dpadX{0.0f};
    std::atomic<float> dpadY{0.0f};

    // Console Screen Mode: 0 = CRT Scope & Registers, 1 = 32-Step 4-Bit Wave RAM Editor, 2 = 8-Step Tracker Arp Grid
    std::atomic<int> screenMode{0};

    // Built-in Console WAV Recorder state (works in both VST3 & Standalone!)
    std::atomic<bool> isRecordingWav{false};
    std::atomic<uint32_t> recordedFramesCount{0};
    char lastSavedWavPath[256]{};

    static constexpr int kScopeSize = 512;
    std::atomic<float> scopeBuffer[kScopeSize];
    std::atomic<uint32_t> scopeWritePos{0};

    SharedSynthBridge() {
        for (int i = 0; i < 8; ++i) {
            arpDutySteps[i].store(i % 4, std::memory_order_relaxed);
        }
        applyPreset(0);
        for (int i = 0; i < kScopeSize; ++i) {
            scopeBuffer[i].store(0.0f, std::memory_order_relaxed);
        }
    }

    void applyPreset(int idx) {
        if (idx < 0 || idx >= kNumPresets) return;
        currentPreset.store(idx, std::memory_order_relaxed);
        for (uint32_t p = 0; p < kNumParams; ++p) {
            // Preserve current Console Skin if user manually switched skin, or load preset skin on initial load
            params[p].store(kFactoryPresets[idx].values[p], std::memory_order_relaxed);
        }
        for (int s = 0; s < 32; ++s) {
            waveRam[s].store(kFactoryPresets[idx].waveRam[s] & 0x0F, std::memory_order_relaxed);
        }
        for (int a = 0; a < 8; ++a) {
            arpSteps[a].store(kFactoryPresets[idx].arpSteps[a], std::memory_order_relaxed);
        }
    }

    void randomizeGlitchPatch(uint32_t seed) {
        auto nextRand = [&seed]() -> float {
            seed = seed * 1664525u + 1013904223u;
            return static_cast<float>((seed >> 8) & 0xFFFF) / 65535.0f;
        };
        params[kParamChipMode].store(std::floor(nextRand() * 4.0f) / 3.0f, std::memory_order_relaxed);
        params[kParamPulseDuty].store(nextRand(), std::memory_order_relaxed);
        params[kParamSubWaveLevel].store(0.35f + nextRand() * 0.65f, std::memory_order_relaxed);
        params[kParamNoiseLevel].store(nextRand() * 0.45f, std::memory_order_relaxed);
        params[kParamNoiseMode].store(std::floor(nextRand() * 3.0f) * 0.5f, std::memory_order_relaxed);
        params[kParamPitchSweep].store(nextRand() > 0.35f ? 0.50f : (0.15f + nextRand() * 0.70f), std::memory_order_relaxed);
        params[kParamVibratoRate].store(0.30f + nextRand() * 0.55f, std::memory_order_relaxed);
        params[kParamVibratoDepth].store(nextRand() * 0.35f, std::memory_order_relaxed);
        params[kParamEnvAttack].store(nextRand() * 0.08f, std::memory_order_relaxed);
        params[kParamEnvDecay].store(0.20f + nextRand() * 0.55f, std::memory_order_relaxed);
        params[kParamEnvSustain].store(0.25f + nextRand() * 0.70f, std::memory_order_relaxed);
        params[kParamEnvRelease].store(0.10f + nextRand() * 0.35f, std::memory_order_relaxed);
        params[kParamArpEnable].store(nextRand() > 0.40f ? 1.0f : 0.0f, std::memory_order_relaxed);
        params[kParamArpPattern].store(std::floor(nextRand() * 6.0f) / 5.0f, std::memory_order_relaxed);
        params[kParamArpSpeed].store(0.60f + nextRand() * 0.38f, std::memory_order_relaxed);
        params[kParamDacBits].store(nextRand() * 0.35f, std::memory_order_relaxed);
        params[kParamSampleRateCrush].store(nextRand() * 0.30f, std::memory_order_relaxed);
        params[kParamFilterCutoff].store(0.45f + nextRand() * 0.55f, std::memory_order_relaxed);
        params[kParamFilterReso].store(nextRand() * 0.60f, std::memory_order_relaxed);
        params[kParamEchoTime].store(0.20f + nextRand() * 0.45f, std::memory_order_relaxed);
        params[kParamEchoFeedback].store(0.20f + nextRand() * 0.40f, std::memory_order_relaxed);
        params[kParamEchoMix].store(0.10f + nextRand() * 0.35f, std::memory_order_relaxed);

        static const int8_t kMusicalIntervals[10] = {0, 3, 4, 5, 7, 10, 12, 15, 19, 24};
        for (int i = 0; i < 8; ++i) {
            int idx = static_cast<int>(nextRand() * 9.99f);
            arpSteps[i].store(kMusicalIntervals[idx], std::memory_order_relaxed);
        }
        for (int s = 0; s < 32; ++s) {
            uint8_t v = static_cast<uint8_t>(std::clamp(static_cast<int>(nextRand() * 16.0f), 0, 15));
            waveRam[s].store(v, std::memory_order_relaxed);
        }
    }

    void pushUiNoteEvent(int16_t pitch, float velocity, bool isNoteOn) {
        uint32_t w = uiWriteIdx.load(std::memory_order_relaxed);
        uint32_t nextW = (w + 1) % kQueueSize;
        if (nextW != uiReadIdx.load(std::memory_order_acquire)) {
            uiNoteQueue[w] = {pitch, velocity, isNoteOn};
            uiWriteIdx.store(nextW, std::memory_order_release);
        }
    }

    bool popUiNoteEvent(UiNoteEvent& outEvent) {
        uint32_t r = uiReadIdx.load(std::memory_order_relaxed);
        if (r == uiWriteIdx.load(std::memory_order_acquire)) {
            return false;
        }
        outEvent = uiNoteQueue[r];
        uiReadIdx.store((r + 1) % kQueueSize, std::memory_order_release);
        return true;
    }

    void setKeyActive(int pitch, bool active) {
        if (pitch < 0 || pitch > 127) return;
        if (pitch < 64) {
            uint64_t bit = (1ULL << pitch);
            if (active) activeKeyMaskLo.fetch_or(bit, std::memory_order_relaxed);
            else        activeKeyMaskLo.fetch_and(~bit, std::memory_order_relaxed);
        } else {
            uint64_t bit = (1ULL << (pitch - 64));
            if (active) activeKeyMaskHi.fetch_or(bit, std::memory_order_relaxed);
            else        activeKeyMaskHi.fetch_and(~bit, std::memory_order_relaxed);
        }
    }

    bool isKeyActive(int pitch) const {
        if (pitch < 0 || pitch > 127) return false;
        if (pitch < 64) {
            return (activeKeyMaskLo.load(std::memory_order_relaxed) & (1ULL << pitch)) != 0;
        } else {
            return (activeKeyMaskHi.load(std::memory_order_relaxed) & (1ULL << (pitch - 64))) != 0;
        }
    }
};

} // namespace PixelBlaze
