#pragma once

#include "PixelBlazeParams.h"
#include <cmath>
#include <cstdint>
#include <cstring>
#include <algorithm>
#include <vector>

namespace PixelBlaze {

static constexpr double kTwoPi = 6.28318530717958647692;

// Exact NES 2A03 8-step duty sequences
static constexpr float kNesDutyTable[4][8] = {
    {0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, // 12.5%
    {0.0f, 1.0f, 1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, // 25.0%
    {0.0f, 1.0f, 1.0f, 1.0f, 1.0f, 0.0f, 0.0f, 0.0f}, // 50.0%
    {1.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f}  // 75.0% (25% inverted)
};

struct ChipVoice {
    bool active = false;
    bool heldByKey = false;
    bool sustainedByPedal = false;
    bool releasing = false;
    int16_t midiNote = 60;
    int32_t noteId = -1;
    float velocity = 0.85f;
    uint64_t age = 0;

    // Pitch & Glide
    float currentNoteFloat = 60.0f;
    float targetNoteFloat = 60.0f;
    float sweepSemitones = 0.0f; // Hardware pitch sweep unit offset

    // Oscillators
    double phasePulse1 = 0.0;
    double phasePulse2 = 0.0;
    double phaseSubWave = 0.0;

    // 15-bit LFSR for authentic NES / GameBoy noise
    uint16_t lfsr = 0x7FFF;
    double noisePhase = 0.0;
    float noiseOut = 0.0f;

    // Percussion / DPCM transient envelope
    float drumTransientEnv = 1.0f;
    double drumPhase = 0.0;

    // Envelope (ADSR)
    int envStage = 0; // 0=Off, 1=Attack, 2=Decay, 3=Sustain, 4=Release
    float envLevel = 0.0f;

    // Per-voice 60Hz Vibrato & Tracker Tick
    double vibPhase = 0.0;
    double arpTickPhase = 0.0;
    int arpStepIdx = 0;
};

class ChipEngine {
public:
    static constexpr int kMaxVoices = 12;
    static constexpr int kMaxEchoSamples = 96000; // 2 seconds at 48kHz

    ChipEngine() {
        echoBufL.resize(kMaxEchoSamples, 0.0f);
        echoBufR.resize(kMaxEchoSamples, 0.0f);
        reset();
    }

    void setSampleRate(float sr) {
        sampleRate = std::max(8000.0f, sr);
    }

    void reset() {
        for (int i = 0; i < kMaxVoices; ++i) {
            voices[i] = ChipVoice{};
        }
        std::fill(echoBufL.begin(), echoBufL.end(), 0.0f);
        std::fill(echoBufR.begin(), echoBufR.end(), 0.0f);
        echoWriteIdx = 0;
        svfLowL = svfBandL = svfLowR = svfBandR = 0.0f;
        snhCounter = 0.0f;
        snhHoldL = snhHoldR = 0.0f;
        dcX1L = dcY1L = dcX1R = dcY1R = 0.0f;
    }

    void noteOn(int16_t pitch, float velocity, int32_t noteId, SharedSynthBridge* bridge) {
        if (pitch < 0 || pitch > 127) return;
        float vel = std::clamp(velocity, 0.05f, 1.0f);

        bool mono = bridge && (bridge->params[kParamMonoMode].load(std::memory_order_relaxed) >= 0.5f);
        int vIdx = -1;

        if (mono) {
            vIdx = 0;
            for (int i = 1; i < kMaxVoices; ++i) {
                voices[i].active = false;
                voices[i].heldByKey = false;
            }
        } else {
            // Reuse existing voice with same pitch if active
            for (int i = 0; i < kMaxVoices; ++i) {
                if (voices[i].active && voices[i].midiNote == pitch) {
                    vIdx = i;
                    break;
                }
            }
            if (vIdx < 0) {
                for (int i = 0; i < kMaxVoices; ++i) {
                    if (!voices[i].active) {
                        vIdx = i;
                        break;
                    }
                }
            }
            if (vIdx < 0) {
                // Steal oldest releasing voice, or oldest voice overall
                uint64_t oldestAge = UINT64_MAX;
                for (int i = 0; i < kMaxVoices; ++i) {
                    if (voices[i].releasing && voices[i].age < oldestAge) {
                        oldestAge = voices[i].age;
                        vIdx = i;
                    }
                }
                if (vIdx < 0) {
                    oldestAge = UINT64_MAX;
                    for (int i = 0; i < kMaxVoices; ++i) {
                        if (voices[i].age < oldestAge) {
                            oldestAge = voices[i].age;
                            vIdx = i;
                        }
                    }
                }
            }
        }

        if (vIdx < 0) vIdx = 0;
        ChipVoice& v = voices[vIdx];

        bool wasActive = v.active;
        v.active = true;
        v.heldByKey = true;
        v.sustainedByPedal = false;
        v.releasing = false;
        v.midiNote = pitch;
        v.noteId = noteId;
        v.velocity = vel;
        v.age = ++voiceAgeCounter;

        v.targetNoteFloat = static_cast<float>(pitch);
        if (!wasActive || lastTriggeredPitch < 0) {
            v.currentNoteFloat = v.targetNoteFloat;
        } else {
            v.currentNoteFloat = static_cast<float>(lastTriggeredPitch);
        }
        lastTriggeredPitch = pitch;

        v.sweepSemitones = 0.0f;
        v.drumTransientEnv = 1.0f;
        v.drumPhase = 0.0;
        v.lfsr = 0x7FFF;
        v.envStage = 1; // Attack
        if (!mono || !wasActive) {
            v.arpStepIdx = 0;
            v.arpTickPhase = 0.0;
        }

        if (bridge) {
            bridge->setKeyActive(pitch, true);
        }
    }

    void noteOff(int16_t pitch, int32_t noteId, SharedSynthBridge* bridge) {
        bool pedalDown = bridge && (bridge->params[kParamSustainPedal].load(std::memory_order_relaxed) >= 0.5f);

        for (int i = 0; i < kMaxVoices; ++i) {
            ChipVoice& v = voices[i];
            if (!v.active) continue;
            if (v.midiNote == pitch || (noteId >= 0 && v.noteId == noteId)) {
                v.heldByKey = false;
                if (pedalDown) {
                    v.sustainedByPedal = true;
                } else {
                    v.releasing = true;
                    v.envStage = 4; // Release
                }
            }
        }
        if (bridge) {
            bridge->setKeyActive(pitch, false);
        }
    }

    void panic(SharedSynthBridge* bridge) {
        for (int i = 0; i < kMaxVoices; ++i) {
            voices[i].active = false;
            voices[i].heldByKey = false;
            voices[i].sustainedByPedal = false;
            voices[i].releasing = false;
            voices[i].envStage = 0;
            voices[i].envLevel = 0.0f;
        }
        if (bridge) {
            bridge->activeKeyMaskLo.store(0, std::memory_order_relaxed);
            bridge->activeKeyMaskHi.store(0, std::memory_order_relaxed);
        }
    }

    static inline float polyBlep(double t, double dt) {
        if (dt <= 0.0 || dt >= 0.5) return 0.0f;
        if (t < dt) {
            double x = t / dt;
            return static_cast<float>(x + x - x * x - 1.0);
        } else if (t > 1.0 - dt) {
            double x = (t - 1.0) / dt;
            return static_cast<float>(x * x + x + x + 1.0);
        }
        return 0.0f;
    }

    void processBlock(float* outL, float* outR, int numSamples, SharedSynthBridge* bridge) {
        if (!outL || !outR || numSamples <= 0) return;

        // Drain lock-free UI Note events (On-screen keyboard, QWERTY keys, Console 'A' Fire button)
        if (bridge) {
            UiNoteEvent ev{};
            while (bridge->popUiNoteEvent(ev)) {
                if (ev.pitch == -1) {
                    panic(bridge);
                } else if (ev.isNoteOn) {
                    noteOn(ev.pitch, ev.velocity, -1, bridge);
                } else {
                    noteOff(ev.pitch, -1, bridge);
                }
            }
        }

        // Load normalized parameters
        float chipNorm       = bridge ? bridge->params[kParamChipMode].load(std::memory_order_relaxed) : 0.0f;
        float dutyNorm       = bridge ? bridge->params[kParamPulseDuty].load(std::memory_order_relaxed) : 0.34f;
        float subWaveLevel   = bridge ? bridge->params[kParamSubWaveLevel].load(std::memory_order_relaxed) : 0.70f;
        float noiseLevel     = bridge ? bridge->params[kParamNoiseLevel].load(std::memory_order_relaxed) : 0.18f;
        float noiseModeNorm  = bridge ? bridge->params[kParamNoiseMode].load(std::memory_order_relaxed) : 0.0f;
        float sweepNorm      = bridge ? bridge->params[kParamPitchSweep].load(std::memory_order_relaxed) : 0.50f;
        float glideNorm      = bridge ? bridge->params[kParamGlideTime].load(std::memory_order_relaxed) : 0.12f;
        float vibRateNorm    = bridge ? bridge->params[kParamVibratoRate].load(std::memory_order_relaxed) : 0.48f;
        float vibDepthNorm   = bridge ? bridge->params[kParamVibratoDepth].load(std::memory_order_relaxed) : 0.15f;

        float attackNorm     = bridge ? bridge->params[kParamEnvAttack].load(std::memory_order_relaxed) : 0.01f;
        float decayNorm      = bridge ? bridge->params[kParamEnvDecay].load(std::memory_order_relaxed) : 0.35f;
        float sustainNorm    = bridge ? bridge->params[kParamEnvSustain].load(std::memory_order_relaxed) : 0.65f;
        float releaseNorm    = bridge ? bridge->params[kParamEnvRelease].load(std::memory_order_relaxed) : 0.18f;

        bool arpEnabled      = bridge && (bridge->params[kParamArpEnable].load(std::memory_order_relaxed) >= 0.5f);
        float arpPatNorm     = bridge ? bridge->params[kParamArpPattern].load(std::memory_order_relaxed) : 0.0f;
        float arpSpdNorm     = bridge ? bridge->params[kParamArpSpeed].load(std::memory_order_relaxed) : 0.82f;

        float dacBitsNorm    = bridge ? bridge->params[kParamDacBits].load(std::memory_order_relaxed) : 0.15f;
        float srCrushNorm    = bridge ? bridge->params[kParamSampleRateCrush].load(std::memory_order_relaxed) : 0.12f;
        float cutoffNorm     = bridge ? bridge->params[kParamFilterCutoff].load(std::memory_order_relaxed) : 0.85f;
        float resoNorm       = bridge ? bridge->params[kParamFilterReso].load(std::memory_order_relaxed) : 0.20f;
        float fltTypeNorm    = bridge ? bridge->params[kParamFilterType].load(std::memory_order_relaxed) : 0.0f;

        float echoTimeNorm   = bridge ? bridge->params[kParamEchoTime].load(std::memory_order_relaxed) : 0.38f;
        float echoFbNorm     = bridge ? bridge->params[kParamEchoFeedback].load(std::memory_order_relaxed) : 0.35f;
        float echoMixNorm    = bridge ? bridge->params[kParamEchoMix].load(std::memory_order_relaxed) : 0.22f;

        float masterVolNorm  = bridge ? bridge->params[kParamMasterVolume].load(std::memory_order_relaxed) : 0.82f;
        float pitchBendNorm  = bridge ? bridge->params[kParamPitchBend].load(std::memory_order_relaxed) : 0.50f;
        float modWheelNorm   = bridge ? bridge->params[kParamModWheel].load(std::memory_order_relaxed) : 0.00f;
        bool pedalDown       = bridge && (bridge->params[kParamSustainPedal].load(std::memory_order_relaxed) >= 0.5f);

        // Apply D-Pad X/Y interactive performance modulation
        float dpadX = bridge ? bridge->dpadX.load(std::memory_order_relaxed) : 0.0f;
        float dpadY = bridge ? bridge->dpadY.load(std::memory_order_relaxed) : 0.0f;
        cutoffNorm = std::clamp(cutoffNorm + dpadX * 0.35f, 0.02f, 1.0f);
        dutyNorm   = std::clamp(dutyNorm + dpadX * 0.25f, 0.0f, 1.0f);
        vibDepthNorm = std::clamp(vibDepthNorm + std::max(0.0f, dpadY * 0.45f) + modWheelNorm * 0.45f, 0.0f, 1.0f);

        // Release pedal-sustained voices if pedal was lifted
        if (!pedalDown) {
            for (int i = 0; i < kMaxVoices; ++i) {
                if (voices[i].active && voices[i].sustainedByPedal && !voices[i].heldByKey) {
                    voices[i].sustainedByPedal = false;
                    voices[i].releasing = true;
                    voices[i].envStage = 4;
                }
            }
        }

        int chipMode = std::clamp(static_cast<int>( std::round(chipNorm * 3.0f) ), 0, 3);
        int noiseMode = std::clamp(static_cast<int>( std::round(noiseModeNorm * 2.0f) ), 0, 2);
        int arpPattern = std::clamp(static_cast<int>( std::round(arpPatNorm * 5.0f) ), 0, 5);
        int filterType = std::clamp(static_cast<int>( std::round(fltTypeNorm * 2.0f) ), 0, 2);

        // Load 32-step 4-bit Wave RAM and 8-step Tracker Arp table
        float waveTableFloat[32];
        int8_t customArp[8];
        if (bridge) {
            for (int s = 0; s < 32; ++s) {
                uint8_t val4 = bridge->waveRam[s].load(std::memory_order_relaxed) & 0x0F;
                waveTableFloat[s] = (static_cast<float>(val4) / 7.5f) - 1.0f;
            }
            for (int a = 0; a < 8; ++a) {
                customArp[a] = bridge->arpSteps[a].load(std::memory_order_relaxed);
            }
        } else {
            for (int s = 0; s < 32; ++s) waveTableFloat[s] = (s < 16) ? 1.0f : -1.0f;
            for (int a = 0; a < 8; ++a) customArp[a] = 0;
        }

        // Compute Envelope increments per sample
        float attackSec  = 0.001f + attackNorm * attackNorm * 1.4f;
        float decaySec   = 0.012f + decayNorm * decayNorm * 2.4f;
        float sustainLvl = std::clamp(sustainNorm, 0.0f, 1.0f);
        float releaseSec = 0.008f + releaseNorm * releaseNorm * 2.2f;

        float attackInc  = 1.0f / (attackSec * sampleRate);
        float decayInc   = (1.0f - sustainLvl) / (decaySec * sampleRate);
        float releaseInc = 1.0f / (releaseSec * sampleRate);

        // Glide coefficient
        float glideTimeSec = (glideNorm <= 0.01f) ? 0.0002f : (0.002f + glideNorm * glideNorm * 0.45f);
        float glideCoeff = 1.0f - std::exp(-1.0f / (glideTimeSec * sampleRate));

        // Hardware Pitch Sweep speed (semitones per sample)
        float sweepDelta = (sweepNorm - 0.50f) * 2.0f; // -1 .. +1
        float sweepRatePerSample = 0.0f;
        if (std::fabs(sweepDelta) > 0.04f) {
            sweepRatePerSample = (sweepDelta * 36.0f) / sampleRate; // up to +/- 36 semitones/sec
        }

        // 60Hz Stepped Vibrato LFO
        float vibFreqHz = 1.5f + vibRateNorm * 12.5f;
        float vibSemiDepth = vibDepthNorm * vibDepthNorm * 2.2f;

        // Tracker Arpeggiator tick rate (10 Hz .. 60 Hz NTSC)
        float arpTickHz = 10.0f + arpSpdNorm * 50.0f;

        // Duty cycle index (0=12.5%, 1=25%, 2=50%, 3=75%) and continuous pulse width
        int dutyIdx = std::clamp(static_cast<int>(dutyNorm * 3.99f), 0, 3);
        static constexpr float kDutyWidths[4] = {0.125f, 0.25f, 0.50f, 0.75f};
        float pulseWidth = (chipMode == 2) ? (0.08f + dutyNorm * 0.84f) : kDutyWidths[dutyIdx];

        // DAC Quantization steps (4-bit = 16 steps up to 12-bit = 4096 steps)
        float dacBits = 4.0f + dacBitsNorm * 8.0f;
        float dacSteps = std::pow(2.0f, dacBits);

        // Sample-Rate Decimation hold period (1.0 = no decimation, up to 12x hold)
        float snhPeriod = 1.0f + srCrushNorm * srCrushNorm * 11.0f;

        // SID 6581 State-Variable Filter coefficients
        float cutoffHz = 90.0f * std::pow(190.0f, cutoffNorm);
        cutoffHz = std::min(cutoffHz, sampleRate * 0.44f);
        float svfF = 2.0f * std::sin(3.14159265f * cutoffHz / sampleRate);
        float svfQ = 1.0f - std::clamp(resoNorm * 0.88f, 0.0f, 0.88f);

        // Chiptune Echo Delay parameters
        int delaySamplesL = std::clamp(static_cast<int>((0.045f + echoTimeNorm * 0.42f) * sampleRate), 64, kMaxEchoSamples - 1);
        int delaySamplesR = std::clamp(static_cast<int>(delaySamplesL * 0.75f), 64, kMaxEchoSamples - 1); // Stereo tracker offset
        float echoFeedback = std::clamp(echoFbNorm * 0.82f, 0.0f, 0.85f);
        float echoMix = std::clamp(echoMixNorm, 0.0f, 1.0f);

        float pitchBendSemis = (pitchBendNorm - 0.50f) * 24.0f + dpadY * 2.0f;
        float masterGain = masterVolNorm * 0.85f;

        float peakL = 0.0f;
        float peakR = 0.0f;
        int activeCount = 0;

        static constexpr int8_t kArpPresetTables[5][8] = {
            {0, 4, 7, 12, 7, 4, 0, 12},     // 0: Major/Chord Up-Down
            {12, 7, 3, 0, 3, 7, 12, 15},    // 1: Minor/Chord Down
            {0, 12, 0, 12, 0, 12, 0, 12},   // 2: Classic 60Hz Octave Bass/Lead
            {0, 12, 24, 12, 0, 7, 12, 24},  // 3: Mega 3-Octave Blaster
            {0, 5, 5, 5, 5, 5, 5, 5}        // 4: 1-Up Coin Pickup (B -> E hold)
        };

        for (int s = 0; s < numSamples; ++s) {
            float sumL = 0.0f;
            float sumR = 0.0f;
            activeCount = 0;

            for (int vIdx = 0; vIdx < kMaxVoices; ++vIdx) {
                ChipVoice& v = voices[vIdx];
                if (!v.active) continue;

                // Advance ADSR Envelope
                if (v.envStage == 1) {
                    v.envLevel += attackInc;
                    if (v.envLevel >= 1.0f) {
                        v.envLevel = 1.0f;
                        v.envStage = 2;
                    }
                } else if (v.envStage == 2) {
                    v.envLevel -= decayInc;
                    if (v.envLevel <= sustainLvl) {
                        v.envLevel = sustainLvl;
                        v.envStage = 3;
                    }
                } else if (v.envStage == 3) {
                    v.envLevel = sustainLvl;
                } else if (v.envStage == 4) {
                    v.envLevel -= releaseInc;
                    if (v.envLevel <= 0.0001f) {
                        v.envLevel = 0.0f;
                        v.envStage = 0;
                        v.active = false;
                        continue;
                    }
                }

                activeCount++;

                // Authentic 4-bit (16-step) hardware envelope quantization for NES/DMG/SN76489
                float envQuant = v.envLevel;
                if (dacBitsNorm < 0.45f) {
                    envQuant = std::ceil(v.envLevel * 15.0f) / 15.0f;
                }

                // Portamento Glide & Hardware Pitch Sweep Unit
                v.currentNoteFloat += (v.targetNoteFloat - v.currentNoteFloat) * glideCoeff;
                if (sweepRatePerSample != 0.0f) {
                    v.sweepSemitones = std::clamp(v.sweepSemitones + sweepRatePerSample, -36.0f, 36.0f);
                }

                // Tracker Arpeggiator Step
                float arpSemitoneOffset = 0.0f;
                int stepDutyOverride = dutyIdx;
                if (arpEnabled) {
                    v.arpTickPhase += arpTickHz / sampleRate;
                    if (v.arpTickPhase >= 1.0) {
                        v.arpTickPhase -= 1.0;
                        // For Coin 1-Up pattern (pattern 4), clamp at step 7 so it holds the second note
                        if (arpPattern == 4) {
                            v.arpStepIdx = std::min(7, v.arpStepIdx + 1);
                        } else {
                            v.arpStepIdx = (v.arpStepIdx + 1) & 7;
                        }
                        if (bridge && vIdx == 0) {
                            bridge->activeArpStep.store(v.arpStepIdx, std::memory_order_relaxed);
                        }
                    }
                    if (arpPattern == 5) {
                        arpSemitoneOffset = static_cast<float>(customArp[v.arpStepIdx & 7]);
                    } else {
                        arpSemitoneOffset = static_cast<float>(kArpPresetTables[arpPattern][v.arpStepIdx & 7]);
                    }
                    if (bridge) {
                        stepDutyOverride = bridge->arpDutySteps[v.arpStepIdx & 7].load(std::memory_order_relaxed) & 3;
                    }
                }

                // 60Hz Stepped Vibrato
                v.vibPhase += vibFreqHz / sampleRate;
                if (v.vibPhase >= 1.0) v.vibPhase -= 1.0;
                // Quantize vibrato LFO phase to 8 steps to emulate 60Hz NES frame updates
                double steppedVibPhase = std::floor(v.vibPhase * 8.0) / 8.0;
                float vibOffset = static_cast<float>(std::sin(steppedVibPhase * kTwoPi)) * vibSemiDepth;

                float effectivePitch = v.currentNoteFloat + arpSemitoneOffset + v.sweepSemitones + vibOffset + pitchBendSemis;
                effectivePitch = std::clamp(effectivePitch, 12.0f, 120.0f);
                double freq = 440.0 * std::pow(2.0, (effectivePitch - 69.0) / 12.0);
                double dt = freq / sampleRate;

                // Advance Main & Detuned/Sub Oscillator Phases
                v.phasePulse1 += dt;
                if (v.phasePulse1 >= 1.0) v.phasePulse1 -= 1.0;

                double dt2 = (chipMode == 3) ? (dt * 1.0055) : (dt * 1.0022); // Slight hardware crystal detune
                v.phasePulse2 += dt2;
                if (v.phasePulse2 >= 1.0) v.phasePulse2 -= 1.0;

                // Sub/Triangle/Wave RAM runs 1 octave down in NES/SID bass or unison in DMG wave
                double dtSub = (chipMode == 0) ? (dt * 0.5) : dt;
                v.phaseSubWave += dtSub;
                if (v.phaseSubWave >= 1.0) v.phaseSubWave -= 1.0;

                // --- Synthesize per Sound Chip Architecture ---
                float voiceL = 0.0f;
                float voiceR = 0.0f;

                if (chipMode == 0) {
                    // ========================================================
                    // CHIP 0: NES / FAMICOM (Ricoh 2A03)
                    // ========================================================
                    int dIdx = arpEnabled ? ((dutyIdx + (stepDutyOverride & 1)) & 3) : dutyIdx;
                    float pw = kDutyWidths[dIdx];

                    // Pulse 1 with PolyBLEP + raw hardware edge blend
                    float p1 = (v.phasePulse1 < pw) ? 1.0f : -1.0f;
                    p1 += polyBlep(v.phasePulse1, dt) * 0.75f;
                    p1 -= polyBlep(std::fmod(v.phasePulse1 - pw + 1.0, 1.0), dt) * 0.75f;

                    // Pulse 2 (slightly detuned for thick Famicom dual-pulse chorus)
                    float p2 = (v.phasePulse2 < pw) ? 1.0f : -1.0f;
                    p2 += polyBlep(v.phasePulse2, dt2) * 0.75f;
                    p2 -= polyBlep(std::fmod(v.phasePulse2 - pw + 1.0, 1.0), dt2) * 0.75f;

                    // 32-step 4-bit Quantized NES Triangle Wave
                    int triStep = static_cast<int>(v.phaseSubWave * 32.0) & 31;
                    float tri4Bit = (static_cast<float>(kNesTriangleTable[triStep]) / 7.5f) - 1.0f;

                    // Non-linear NES 2A03 DAC compression simulation
                    float pulseMix = (p1 * 0.65f + p2 * 0.35f) * envQuant;
                    float tndMix   = tri4Bit * subWaveLevel * envQuant;
                    float raw = std::tanh((pulseMix * 0.70f + tndMix * 0.85f) * 1.35f);
                    voiceL = raw * 0.95f;
                    voiceR = (std::tanh((p2 * 0.65f + p1 * 0.35f) * envQuant * 0.70f + tndMix * 0.85f)) * 0.95f;

                } else if (chipMode == 1) {
                    // ========================================================
                    // CHIP 1: GAME BOY (Sharp LR35902 / DMG-01)
                    // ========================================================
                    float pw = kDutyWidths[dutyIdx];
                    int seqStep1 = static_cast<int>(v.phasePulse1 * 8.0) & 7;
                    int seqStep2 = static_cast<int>(v.phasePulse2 * 8.0) & 7;
                    float gbPulse1 = kNesDutyTable[dutyIdx][seqStep1] * 2.0f - 1.0f;
                    float gbPulse2 = kNesDutyTable[(dutyIdx + 1) & 3][seqStep2] * 2.0f - 1.0f;
                    gbPulse1 += polyBlep(v.phasePulse1, dt) * 0.5f;
                    gbPulse1 -= polyBlep(std::fmod(v.phasePulse1 - pw + 1.0, 1.0), dt) * 0.5f;

                    // Custom 32-Step 4-Bit Wave RAM Channel (`$FF30-$FF3F`)
                    int waveIdx = static_cast<int>(v.phaseSubWave * 32.0) & 31;
                    float customWave = waveTableFloat[waveIdx];

                    // DMG hard-stereo panning character (Pulse 1 slightly L, Pulse 2 slightly R, Wave centered)
                    voiceL = (gbPulse1 * 0.55f + gbPulse2 * 0.20f + customWave * subWaveLevel * 0.95f) * envQuant;
                    voiceR = (gbPulse1 * 0.20f + gbPulse2 * 0.55f + customWave * subWaveLevel * 0.95f) * envQuant;

                } else if (chipMode == 2) {
                    // ========================================================
                    // CHIP 2: COMMODORE 64 (MOS 6581 / 8580 SID)
                    // ========================================================
                    // Continuous PWM modulated by vibrato/LFO
                    float sidPw = std::clamp(pulseWidth + static_cast<float>(std::sin(v.vibPhase * kTwoPi)) * 0.18f, 0.05f, 0.95f);
                    float sidPulse = (v.phasePulse1 < sidPw) ? 1.0f : -1.0f;
                    sidPulse += polyBlep(v.phasePulse1, dt);
                    sidPulse -= polyBlep(std::fmod(v.phasePulse1 - sidPw + 1.0, 1.0), dt);

                    // SID 12-bit Sawtooth + Triangle combined waveform
                    float sidSaw = static_cast<float>(2.0 * v.phasePulse2 - 1.0) - polyBlep(v.phasePulse2, dt2);
                    float sidTri = static_cast<float>(1.0 - 4.0 * std::fabs(v.phaseSubWave - 0.5));
                    // Ring-mod overtone blend
                    float ringMod = sidPulse * sidTri * 0.25f;

                    voiceL = (sidPulse * 0.55f + (sidSaw * 0.65f + sidTri * 0.35f + ringMod) * subWaveLevel) * envQuant;
                    voiceR = (sidPulse * 0.45f + (sidSaw * 0.75f + sidTri * 0.35f - ringMod) * subWaveLevel) * envQuant;

                } else {
                    // ========================================================
                    // CHIP 3: SEGA MASTER SYSTEM / COLECOVISION (TI SN76489)
                    // ========================================================
                    // 3 Square Wave Tone Generators (50% Fixed Duty with rich triad/chorus detune)
                    float sq1 = (v.phasePulse1 < 0.5) ? 1.0f : -1.0f;
                    sq1 += polyBlep(v.phasePulse1, dt);
                    sq1 -= polyBlep(std::fmod(v.phasePulse1 + 0.5, 1.0), dt);

                    float sq2 = (v.phasePulse2 < 0.5) ? 1.0f : -1.0f;
                    sq2 += polyBlep(v.phasePulse2, dt2);
                    sq2 -= polyBlep(std::fmod(v.phasePulse2 + 0.5, 1.0), dt2);

                    int waveIdx = static_cast<int>(v.phaseSubWave * 32.0) & 31;
                    float sq3 = (v.phaseSubWave < 0.5 ? 0.7f : -0.7f) + waveTableFloat[waveIdx] * 0.3f;

                    voiceL = (sq1 * 0.55f + sq2 * 0.25f + sq3 * subWaveLevel * 0.65f) * envQuant;
                    voiceR = (sq1 * 0.25f + sq2 * 0.55f + sq3 * subWaveLevel * 0.65f) * envQuant;
                }

                // --- 15-Bit LFSR Noise & 8-Bit Percussion Transient Layer ---
                if (noiseLevel > 0.005f) {
                    // Clock LFSR at pitch-dependent or fixed NES noise divider rate
                    double noiseClockHz = (noiseMode == 2)
                        ? (1800.0 + 6500.0 * v.drumTransientEnv)
                        : std::clamp(freq * 4.0, 800.0, 22000.0);

                    v.noisePhase += noiseClockHz / sampleRate;
                    while (v.noisePhase >= 1.0) {
                        v.noisePhase -= 1.0;
                        // Tap bit 6 for 93-step Metallic NES Noise, or bit 1 for 32,767-step White Noise
                        int tapBit = (noiseMode == 1) ? 6 : 1;
                        uint16_t bit0 = v.lfsr & 1u;
                        uint16_t bitTap = (v.lfsr >> tapBit) & 1u;
                        uint16_t fb = (bit0 ^ bitTap) & 1u;
                        v.lfsr = (v.lfsr >> 1) | (fb << 14);
                        v.noiseOut = (v.lfsr & 1u) ? 1.0f : -1.0f;
                    }

                    if (noiseMode == 2) {
                        // Mode 2: 8-Bit DPCM Kick/Snare Attack Transient (decays rapidly after Note-On)
                        v.drumTransientEnv *= std::exp(-18.0f / sampleRate);
                        double kickHz = 55.0 + 260.0 * v.drumTransientEnv * v.drumTransientEnv;
                        v.drumPhase += kickHz / sampleRate;
                        if (v.drumPhase >= 1.0) v.drumPhase -= 1.0;
                        float dpcmKick = (v.drumPhase < 0.5) ? 1.0f : -1.0f;
                        float transientSig = (dpcmKick * 0.65f + v.noiseOut * 0.55f) * v.drumTransientEnv * noiseLevel;
                        voiceL += transientSig;
                        voiceR += transientSig;
                    } else {
                        // Sustained White or Metallic 93-step LFSR Noise
                        float ns = v.noiseOut * noiseLevel * envQuant * 0.65f;
                        voiceL += ns;
                        voiceR += ns;
                    }
                }

                sumL += voiceL * v.velocity * 0.35f;
                sumR += voiceR * v.velocity * 0.35f;
            }

            // --- Hardware Quirk 1: Sample-Rate Decimator (Zero-Order Hold Aliasing) ---
            snhCounter += 1.0f;
            if (snhCounter >= snhPeriod) {
                snhCounter -= snhPeriod;
                snhHoldL = sumL;
                snhHoldR = sumR;
            }
            float procL = snhHoldL;
            float procR = snhHoldR;

            // --- Hardware Quirk 2: 4-Bit / 8-Bit DAC Stair-Step Quantizer ---
            if (dacBitsNorm < 0.95f) {
                procL = std::round(procL * dacSteps) / dacSteps;
                procR = std::round(procR * dacSteps) / dacSteps;
            }

            // --- MOS 6581 SID Resonant Multimode State-Variable Filter ---
            if (cutoffNorm < 0.98f || resoNorm > 0.05f || filterType != 0) {
                // Non-linear FET saturation inside SID filter feedback loop
                float hpL = procL - svfLowL - svfQ * std::tanh(svfBandL * 1.4f);
                svfBandL += svfF * hpL;
                svfLowL  += svfF * svfBandL;

                float hpR = procR - svfLowR - svfQ * std::tanh(svfBandR * 1.4f);
                svfBandR += svfF * hpR;
                svfLowR  += svfF * svfBandR;

                if (filterType == 0) {
                    procL = svfLowL;
                    procR = svfLowR;
                } else if (filterType == 1) {
                    procL = svfBandL * 1.35f;
                    procR = svfBandR * 1.35f;
                } else {
                    procL = hpL;
                    procR = hpR;
                }
            }

            // --- Stereo Chiptune Tracker Echo / Delay ---
            int readIdxL = (echoWriteIdx - delaySamplesL + kMaxEchoSamples) % kMaxEchoSamples;
            int readIdxR = (echoWriteIdx - delaySamplesR + kMaxEchoSamples) % kMaxEchoSamples;
            float delL = echoBufL[readIdxL];
            float delR = echoBufR[readIdxR];

            // Quantize echo feedback slightly to 6-bit for authentic tracker echo grit
            float fbL = std::round((procL + delR * echoFeedback) * 64.0f) / 64.0f;
            float fbR = std::round((procR + delL * echoFeedback) * 64.0f) / 64.0f;
            echoBufL[echoWriteIdx] = std::clamp(fbL, -1.5f, 1.5f);
            echoBufR[echoWriteIdx] = std::clamp(fbR, -1.5f, 1.5f);
            echoWriteIdx = (echoWriteIdx + 1) % kMaxEchoSamples;

            procL = procL * (1.0f - echoMix * 0.35f) + delL * echoMix;
            procR = procR * (1.0f - echoMix * 0.35f) + delR * echoMix;

            // --- Console Output High-Pass DC Blocker & Soft CRT Limiter ---
            float yL = procL - dcX1L + 0.996f * dcY1L;
            dcX1L = procL;
            dcY1L = yL;

            float yR = procR - dcX1R + 0.996f * dcY1R;
            dcX1R = procR;
            dcY1R = yR;

            float finalL = std::tanh(yL * masterGain * 1.4f);
            float finalR = std::tanh(yR * masterGain * 1.4f);

            outL[s] = finalL;
            outR[s] = finalR;

            peakL = std::max(peakL, std::fabs(finalL));
            peakR = std::max(peakR, std::fabs(finalR));

            // Push to CRT Oscilloscope Ring Buffer
            if (bridge && ((s & 1) == 0)) {
                uint32_t wp = bridge->scopeWritePos.load(std::memory_order_relaxed);
                bridge->scopeBuffer[wp & (SharedSynthBridge::kScopeSize - 1)].store((finalL + finalR) * 0.5f, std::memory_order_relaxed);
                bridge->scopeWritePos.store(wp + 1, std::memory_order_relaxed);
            }
        }

        if (bridge) {
            bridge->activeVoiceCount.store(activeCount, std::memory_order_relaxed);
            float prevL = bridge->meterPeakL.load(std::memory_order_relaxed);
            float prevR = bridge->meterPeakR.load(std::memory_order_relaxed);
            bridge->meterPeakL.store(std::max(peakL, prevL * 0.85f), std::memory_order_relaxed);
            bridge->meterPeakR.store(std::max(peakR, prevR * 0.85f), std::memory_order_relaxed);
        }
    }

private:
    float sampleRate = 44100.0f;
    ChipVoice voices[kMaxVoices];
    uint64_t voiceAgeCounter = 0;
    int16_t lastTriggeredPitch = -1;

    // Sample & hold decimator state
    float snhCounter = 0.0f;
    float snhHoldL = 0.0f;
    float snhHoldR = 0.0f;

    // SID 6581 SVF state
    float svfLowL = 0.0f, svfBandL = 0.0f;
    float svfLowR = 0.0f, svfBandR = 0.0f;

    // Stereo Tracker Echo buffer
    std::vector<float> echoBufL;
    std::vector<float> echoBufR;
    int echoWriteIdx = 0;

    // DC blocker state
    float dcX1L = 0.0f, dcY1L = 0.0f;
    float dcX1R = 0.0f, dcY1R = 0.0f;
};

} // namespace PixelBlaze
