#define INIT_CLASS_IID

#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ustring.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivstunits.h"

#include "PixelBlazeParams.h"
#include "ChipEngine.h"
#include "PixelBlazeGUI.h"

#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <memory>
#include <vector>

namespace PixelBlaze {

using namespace Steinberg;
using namespace Steinberg::Vst;

// Unique Class UIDs for Pixel-Blaze 1999 Processor and Controller
static const TUID kPixelBlazeProcessorUID  = INLINE_UID(0x88B1A299, 0x19994F01, 0x9C44E812, 0x55A01999);
static const TUID kPixelBlazeControllerUID = INLINE_UID(0x88B1A299, 0x19994F01, 0x9C44E812, 0x55A0199A);
static const TUID kPixelBlazeBridgeIID     = INLINE_UID(0x88B1A299, 0x19994F01, 0x9C44E812, 0x55A0199B);

class IPixelBlazeBridgeProvider : public FUnknown {
public:
    virtual std::shared_ptr<SharedSynthBridge> getSharedBridge() = 0;
};

static void copyAsciiToString128(String128 dst, const char* src) {
    if (!dst) return;
    int i = 0;
    if (src) {
        for (; i < 127 && src[i] != '\0'; ++i) {
            dst[i] = static_cast<TChar>(static_cast<unsigned char>(src[i]));
        }
    }
    dst[i] = 0;
}

static void string128ToAscii(const TChar* src, char* dst, size_t maxLen) {
    if (!dst || maxLen == 0) return;
    size_t i = 0;
    if (src) {
        for (; i + 1 < maxLen && src[i] != 0; ++i) {
            dst[i] = static_cast<char>(src[i] & 0x7F);
        }
    }
    dst[i] = '\0';
}

static std::shared_ptr<SharedSynthBridge>& getLastCreatedBridgeSlot() {
    static std::shared_ptr<SharedSynthBridge> sLastBridge;
    return sLastBridge;
}

static constexpr uint32_t kStateMagic = 0x50584239; // 'PXB9'

static bool writeCapturedWavFile(const char* path, const std::vector<float>& left, const std::vector<float>& right, int sampleRate) {
    if (left.empty()) return false;
    FILE* f = std::fopen(path, "wb");
    if (!f) return false;
    uint32_t numSamples = static_cast<uint32_t>(left.size());
    uint32_t dataSize = numSamples * 2 * sizeof(int16_t);
    uint32_t riffSize = 36 + dataSize;
    uint16_t audioFormat = 1;
    uint16_t numChannels = 2;
    uint32_t sr = static_cast<uint32_t>(sampleRate);
    uint32_t byteRate = sr * 2 * sizeof(int16_t);
    uint16_t blockAlign = 2 * sizeof(int16_t);
    uint16_t bitsPerSample = 16;

    std::fwrite("RIFF", 1, 4, f);
    std::fwrite(&riffSize, 4, 1, f);
    std::fwrite("WAVEfmt ", 1, 8, f);
    uint32_t fmtSize = 16;
    std::fwrite(&fmtSize, 4, 1, f);
    std::fwrite(&audioFormat, 2, 1, f);
    std::fwrite(&numChannels, 2, 1, f);
    std::fwrite(&sr, 4, 1, f);
    std::fwrite(&byteRate, 4, 1, f);
    std::fwrite(&blockAlign, 2, 1, f);
    std::fwrite(&bitsPerSample, 2, 1, f);
    std::fwrite("data", 1, 4, f);
    std::fwrite(&dataSize, 4, 1, f);

    for (uint32_t i = 0; i < numSamples; ++i) {
        int16_t sL = static_cast<int16_t>(std::clamp(left[i], -1.0f, 1.0f) * 32767.0f);
        int16_t sR = static_cast<int16_t>(std::clamp(right[i], -1.0f, 1.0f) * 32767.0f);
        std::fwrite(&sL, 2, 1, f);
        std::fwrite(&sR, 2, 1, f);
    }
    std::fclose(f);
    return true;
}

// ============================================================================
// PixelBlazeProcessor
// ============================================================================
class PixelBlazeProcessor : public IComponent,
                            public IAudioProcessor,
                            public IProcessContextRequirements,
                            public IConnectionPoint,
                            public IPixelBlazeBridgeProvider {
public:
    PixelBlazeProcessor() {
        bridge = std::make_shared<SharedSynthBridge>();
        getLastCreatedBridgeSlot() = bridge;
        tempL.resize(4096, 0.0f);
        tempR.resize(4096, 0.0f);
    }

    virtual ~PixelBlazeProcessor() = default;

    // --- FUnknown ---
    tresult PLUGIN_API queryInterface(const TUID _iid, void** obj) override {
        if (FUnknownPrivate::iidEqual(_iid, FUnknown::iid) ||
            FUnknownPrivate::iidEqual(_iid, IPluginBase::iid) ||
            FUnknownPrivate::iidEqual(_iid, IComponent::iid)) {
            addRef();
            *obj = static_cast<IComponent*>(this);
            return kResultOk;
        }
        if (FUnknownPrivate::iidEqual(_iid, IAudioProcessor::iid)) {
            addRef();
            *obj = static_cast<IAudioProcessor*>(this);
            return kResultOk;
        }
        if (FUnknownPrivate::iidEqual(_iid, IProcessContextRequirements::iid)) {
            addRef();
            *obj = static_cast<IProcessContextRequirements*>(this);
            return kResultOk;
        }
        if (FUnknownPrivate::iidEqual(_iid, IConnectionPoint::iid)) {
            addRef();
            *obj = static_cast<IConnectionPoint*>(this);
            return kResultOk;
        }
        if (FUnknownPrivate::iidEqual(_iid, kPixelBlazeBridgeIID)) {
            addRef();
            *obj = static_cast<IPixelBlazeBridgeProvider*>(this);
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 PLUGIN_API addRef() override { return ++refCount; }
    uint32 PLUGIN_API release() override {
        uint32 r = --refCount;
        if (r == 0) delete this;
        return r;
    }

    std::shared_ptr<SharedSynthBridge> getSharedBridge() override { return bridge; }

    // --- IPluginBase ---
    tresult PLUGIN_API initialize(FUnknown* context) override {
        (void)context;
        return kResultOk;
    }

    tresult PLUGIN_API terminate() override {
        return kResultOk;
    }

    // --- IComponent ---
    tresult PLUGIN_API getControllerClassId(TUID classId) override {
        std::memcpy(classId, kPixelBlazeControllerUID, sizeof(TUID));
        return kResultOk;
    }

    tresult PLUGIN_API setIoMode(IoMode mode) override {
        (void)mode;
        return kResultOk;
    }

    int32 PLUGIN_API getBusCount(MediaType type, BusDirection dir) override {
        if (type == kAudio && dir == kOutput) return 1;
        if (type == kEvent && dir == kInput) return 1;
        return 0;
    }

    tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo& bus) override {
        if (type == kAudio && dir == kOutput && index == 0) {
            bus.mediaType = kAudio;
            bus.direction = kOutput;
            bus.channelCount = 2;
            copyAsciiToString128(bus.name, "Stereo Output");
            bus.busType = kMain;
            bus.flags = BusInfo::kDefaultActive;
            return kResultOk;
        }
        if (type == kEvent && dir == kInput && index == 0) {
            bus.mediaType = kEvent;
            bus.direction = kInput;
            bus.channelCount = 1;
            copyAsciiToString128(bus.name, "MIDI Event Input");
            bus.busType = kMain;
            bus.flags = BusInfo::kDefaultActive;
            return kResultOk;
        }
        return kInvalidArgument;
    }

    tresult PLUGIN_API getRoutingInfo(RoutingInfo& inInfo, RoutingInfo& outInfo) override {
        (void)inInfo; (void)outInfo;
        return kNotImplemented;
    }

    tresult PLUGIN_API activateBus(MediaType type, BusDirection dir, int32 index, TBool state) override {
        if ((type == kAudio && dir == kOutput && index == 0) ||
            (type == kEvent && dir == kInput && index == 0)) {
            (void)state;
            return kResultOk;
        }
        return kInvalidArgument;
    }

    tresult PLUGIN_API setActive(TBool state) override {
        if (!state) {
            engine.panic(bridge.get());
        }
        return kResultOk;
    }

    tresult PLUGIN_API setState(IBStream* state) override {
        if (!state) return kInvalidArgument;
        uint32_t magic = 0;
        int32 bytesRead = 0;
        if (state->read(&magic, sizeof(magic), &bytesRead) != kResultOk || magic != kStateMagic) {
            return kResultFalse;
        }
        int32_t presetIdx = 0;
        state->read(&presetIdx, sizeof(presetIdx), &bytesRead);
        bridge->currentPreset.store(std::clamp(presetIdx, 0, kNumPresets - 1), std::memory_order_relaxed);

        for (uint32_t i = 0; i < kNumParams; ++i) {
            float v = kParamInfo[i].defaultNorm;
            state->read(&v, sizeof(float), &bytesRead);
            bridge->params[i].store(std::clamp(v, 0.0f, 1.0f), std::memory_order_relaxed);
        }
        for (int s = 0; s < 32; ++s) {
            uint8_t w = 8;
            state->read(&w, sizeof(uint8_t), &bytesRead);
            bridge->waveRam[s].store(w & 0x0F, std::memory_order_relaxed);
        }
        for (int a = 0; a < 8; ++a) {
            int8_t st = 0;
            state->read(&st, sizeof(int8_t), &bytesRead);
            bridge->arpSteps[a].store(st, std::memory_order_relaxed);
        }
        return kResultOk;
    }

    tresult PLUGIN_API getState(IBStream* state) override {
        if (!state) return kInvalidArgument;
        uint32_t magic = kStateMagic;
        int32 written = 0;
        state->write(&magic, sizeof(magic), &written);
        int32_t presetIdx = bridge->currentPreset.load(std::memory_order_relaxed);
        state->write(&presetIdx, sizeof(presetIdx), &written);

        for (uint32_t i = 0; i < kNumParams; ++i) {
            float v = bridge->params[i].load(std::memory_order_relaxed);
            state->write(&v, sizeof(float), &written);
        }
        for (int s = 0; s < 32; ++s) {
            uint8_t w = bridge->waveRam[s].load(std::memory_order_relaxed) & 0x0F;
            state->write(&w, sizeof(uint8_t), &written);
        }
        for (int a = 0; a < 8; ++a) {
            int8_t st = bridge->arpSteps[a].load(std::memory_order_relaxed);
            state->write(&st, sizeof(int8_t), &written);
        }
        return kResultOk;
    }

    // --- IAudioProcessor ---
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement* inputs, int32 numIns,
                                          SpeakerArrangement* outputs, int32 numOuts) override {
        (void)inputs;
        if (numIns == 0 && numOuts == 1 && outputs && outputs[0] == SpeakerArr::kStereo) {
            return kResultOk;
        }
        return kResultFalse;
    }

    tresult PLUGIN_API getBusArrangement(BusDirection dir, int32 index, SpeakerArrangement& arr) override {
        if (dir == kOutput && index == 0) {
            arr = SpeakerArr::kStereo;
            return kResultOk;
        }
        return kInvalidArgument;
    }

    tresult PLUGIN_API canProcessSampleSize(int32 symbolicSampleSize) override {
        if (symbolicSampleSize == kSample32 || symbolicSampleSize == kSample64) {
            return kResultTrue;
        }
        return kResultFalse;
    }

    uint32 PLUGIN_API getLatencySamples() override { return 0; }

    tresult PLUGIN_API setupProcessing(ProcessSetup& setup) override {
        currentSampleRate = static_cast<float>(setup.sampleRate);
        engine.setSampleRate(currentSampleRate);
        int maxBlock = std::max<int>(setup.maxSamplesPerBlock, 4096);
        tempL.resize(maxBlock, 0.0f);
        tempR.resize(maxBlock, 0.0f);
        return kResultOk;
    }

    tresult PLUGIN_API setProcessing(TBool state) override {
        (void)state;
        return kResultOk;
    }

    tresult PLUGIN_API process(ProcessData& data) override {
        // 1. Apply incoming parameter automation from FL Studio / VST3 host
        if (data.inputParameterChanges) {
            int32 numQueues = data.inputParameterChanges->getParameterCount();
            for (int32 i = 0; i < numQueues; ++i) {
                IParamValueQueue* queue = data.inputParameterChanges->getParameterData(i);
                if (!queue) continue;
                ParamID pid = static_cast<ParamID>(queue->getParameterId());
                int32 numPts = queue->getPointCount();
                if (numPts > 0 && pid < kNumParams) {
                    int32 sampleOffset = 0;
                    ParamValue value = 0.0;
                    if (queue->getPoint(numPts - 1, sampleOffset, value) == kResultOk) {
                        bridge->params[pid].store(static_cast<float>(std::clamp(value, 0.0, 1.0)), std::memory_order_relaxed);
                    }
                }
            }
        }

        // 2. Process incoming MIDI Note-On / Note-Off events from FL Studio Piano Roll
        if (data.inputEvents) {
            int32 eventCount = data.inputEvents->getEventCount();
            for (int32 i = 0; i < eventCount; ++i) {
                Event e{};
                if (data.inputEvents->getEvent(i, e) == kResultOk) {
                    if (e.type == Event::kNoteOnEvent) {
                        if (e.noteOn.velocity > 0.0f) {
                            engine.noteOn(e.noteOn.pitch, e.noteOn.velocity, e.noteOn.noteId, bridge.get());
                        } else {
                            engine.noteOff(e.noteOn.pitch, e.noteOn.noteId, bridge.get());
                        }
                    } else if (e.type == Event::kNoteOffEvent) {
                        engine.noteOff(e.noteOff.pitch, e.noteOff.noteId, bridge.get());
                    }
                }
            }
        }

        int32 numSamples = data.numSamples;
        if (numSamples <= 0 || data.numOutputs == 0 || !data.outputs) {
            return kResultOk;
        }

        if (static_cast<size_t>(numSamples) > tempL.size()) {
            tempL.resize(numSamples, 0.0f);
            tempR.resize(numSamples, 0.0f);
        }

        engine.processBlock(tempL.data(), tempR.data(), numSamples, bridge.get());

        // Handle On-Console WAV Recorder if active inside VST3
        bool wantRec = bridge->isRecordingWav.load(std::memory_order_relaxed);
        if (wantRec) {
            wasRecordingInPlugin = true;
            if (recCaptureL.size() < 48000 * 60) {
                recCaptureL.insert(recCaptureL.end(), tempL.begin(), tempL.begin() + numSamples);
                recCaptureR.insert(recCaptureR.end(), tempR.begin(), tempR.begin() + numSamples);
            }
        } else if (wasRecordingInPlugin) {
            wasRecordingInPlugin = false;
            if (!recCaptureL.empty()) {
                const char* home = std::getenv("HOME");
                char outPath[256];
                std::snprintf(outPath, sizeof(outPath), "%s/Desktop/PixelBlaze1999_SFX.wav", home ? home : "/tmp");
                if (!writeCapturedWavFile(outPath, recCaptureL, recCaptureR, static_cast<int>(currentSampleRate))) {
                    std::snprintf(outPath, sizeof(outPath), "/tmp/PixelBlaze1999_SFX.wav");
                    writeCapturedWavFile(outPath, recCaptureL, recCaptureR, static_cast<int>(currentSampleRate));
                }
                std::strncpy(bridge->lastSavedWavPath, outPath, sizeof(bridge->lastSavedWavPath) - 1);
                recCaptureL.clear();
                recCaptureR.clear();
            }
        }

        AudioBusBuffers& outBus = data.outputs[0];
        if (data.symbolicSampleSize == kSample32 && outBus.channelBuffers32) {
            if (outBus.numChannels >= 1 && outBus.channelBuffers32[0]) {
                std::memcpy(outBus.channelBuffers32[0], tempL.data(), numSamples * sizeof(float));
            }
            if (outBus.numChannels >= 2 && outBus.channelBuffers32[1]) {
                std::memcpy(outBus.channelBuffers32[1], tempR.data(), numSamples * sizeof(float));
            }
        } else if (data.symbolicSampleSize == kSample64 && outBus.channelBuffers64) {
            for (int32 s = 0; s < numSamples; ++s) {
                if (outBus.numChannels >= 1 && outBus.channelBuffers64[0])
                    outBus.channelBuffers64[0][s] = static_cast<double>(tempL[s]);
                if (outBus.numChannels >= 2 && outBus.channelBuffers64[1])
                    outBus.channelBuffers64[1][s] = static_cast<double>(tempR[s]);
            }
        }
        outBus.silenceFlags = 0;
        return kResultOk;
    }

    uint32 PLUGIN_API getTailSamples() override {
        return static_cast<uint32>(currentSampleRate * 0.8f);
    }

    // --- IProcessContextRequirements ---
    uint32 PLUGIN_API getProcessContextRequirements() override {
        return kNeedTempo | kNeedTransportState;
    }

    // --- IConnectionPoint ---
    tresult PLUGIN_API connect(IConnectionPoint* other) override {
        if (!other) return kInvalidArgument;
        return kResultOk;
    }
    tresult PLUGIN_API disconnect(IConnectionPoint* other) override {
        (void)other;
        return kResultOk;
    }
    tresult PLUGIN_API notify(IMessage* message) override {
        (void)message;
        return kResultOk;
    }

private:
    std::atomic<uint32> refCount{1};
    std::shared_ptr<SharedSynthBridge> bridge;
    ChipEngine engine;
    float currentSampleRate = 44100.0f;
    std::vector<float> tempL;
    std::vector<float> tempR;
    bool wasRecordingInPlugin = false;
    std::vector<float> recCaptureL;
    std::vector<float> recCaptureR;
};

// ============================================================================
// PixelBlazeController (IEditController + IMidiMapping + IUnitInfo + IConnectionPoint)
// ============================================================================
class PixelBlazeController : public IEditController,
                             public IMidiMapping,
                             public IUnitInfo,
                             public IConnectionPoint,
                             public IEditorParamCallback {
public:
    PixelBlazeController() {
        bridge = getLastCreatedBridgeSlot();
        if (!bridge) {
            bridge = std::make_shared<SharedSynthBridge>();
            getLastCreatedBridgeSlot() = bridge;
        }
    }

    virtual ~PixelBlazeController() = default;

    // --- FUnknown ---
    tresult PLUGIN_API queryInterface(const TUID _iid, void** obj) override {
        if (FUnknownPrivate::iidEqual(_iid, FUnknown::iid) ||
            FUnknownPrivate::iidEqual(_iid, IPluginBase::iid) ||
            FUnknownPrivate::iidEqual(_iid, IEditController::iid)) {
            addRef();
            *obj = static_cast<IEditController*>(this);
            return kResultOk;
        }
        if (FUnknownPrivate::iidEqual(_iid, IMidiMapping::iid)) {
            addRef();
            *obj = static_cast<IMidiMapping*>(this);
            return kResultOk;
        }
        if (FUnknownPrivate::iidEqual(_iid, IUnitInfo::iid)) {
            addRef();
            *obj = static_cast<IUnitInfo*>(this);
            return kResultOk;
        }
        if (FUnknownPrivate::iidEqual(_iid, IConnectionPoint::iid)) {
            addRef();
            *obj = static_cast<IConnectionPoint*>(this);
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 PLUGIN_API addRef() override { return ++refCount; }
    uint32 PLUGIN_API release() override {
        uint32 r = --refCount;
        if (r == 0) delete this;
        return r;
    }

    // --- IPluginBase ---
    tresult PLUGIN_API initialize(FUnknown* context) override {
        (void)context;
        return kResultOk;
    }

    tresult PLUGIN_API terminate() override {
        componentHandler = nullptr;
        return kResultOk;
    }

    // --- IEditController ---
    tresult PLUGIN_API setComponentState(IBStream* state) override {
        if (!state) return kInvalidArgument;
        uint32_t magic = 0;
        int32 bytesRead = 0;
        if (state->read(&magic, sizeof(magic), &bytesRead) != kResultOk || magic != kStateMagic) {
            return kResultFalse;
        }
        int32_t presetIdx = 0;
        state->read(&presetIdx, sizeof(presetIdx), &bytesRead);
        bridge->currentPreset.store(std::clamp(presetIdx, 0, kNumPresets - 1), std::memory_order_relaxed);

        for (uint32_t i = 0; i < kNumParams; ++i) {
            float v = kParamInfo[i].defaultNorm;
            state->read(&v, sizeof(float), &bytesRead);
            bridge->params[i].store(std::clamp(v, 0.0f, 1.0f), std::memory_order_relaxed);
        }
        return kResultOk;
    }

    tresult PLUGIN_API setState(IBStream* state) override {
        (void)state;
        return kResultOk;
    }

    tresult PLUGIN_API getState(IBStream* state) override {
        (void)state;
        return kResultOk;
    }

    int32 PLUGIN_API getParameterCount() override {
        return kNumParams;
    }

    tresult PLUGIN_API getParameterInfo(int32 paramIndex, ParameterInfo& info) override {
        if (paramIndex < 0 || paramIndex >= static_cast<int32>(kNumParams)) {
            return kInvalidArgument;
        }
        const ParamMetadata& meta = kParamInfo[paramIndex];
        info.id = meta.id;
        copyAsciiToString128(info.title, meta.title);
        copyAsciiToString128(info.shortTitle, meta.shortTitle);
        copyAsciiToString128(info.units, meta.units);
        info.stepCount = meta.stepCount;
        info.defaultNormalizedValue = meta.defaultNorm;
        info.unitId = kRootUnitId;
        info.flags = ParameterInfo::kCanAutomate;
        return kResultOk;
    }

    tresult PLUGIN_API getParamStringByValue(ParamID id, ParamValue valueNormalized, String128 string) override {
        if (id >= kNumParams) return kInvalidArgument;
        char buf[64];
        std::snprintf(buf, sizeof(buf), "%d%%", static_cast<int>(std::round(valueNormalized * 100.0)));
        copyAsciiToString128(string, buf);
        return kResultOk;
    }

    tresult PLUGIN_API getParamValueByString(ParamID id, TChar* string, ParamValue& valueNormalized) override {
        if (id >= kNumParams || !string) return kInvalidArgument;
        char buf[64];
        string128ToAscii(string, buf, sizeof(buf));
        valueNormalized = std::clamp(std::atof(buf) / 100.0, 0.0, 1.0);
        return kResultOk;
    }

    ParamValue PLUGIN_API normalizedParamToPlain(ParamID id, ParamValue valueNormalized) override {
        (void)id;
        return valueNormalized;
    }

    ParamValue PLUGIN_API plainParamToNormalized(ParamID id, ParamValue plainValue) override {
        (void)id;
        return plainValue;
    }

    ParamValue PLUGIN_API getParamNormalized(ParamID id) override {
        if (id >= kNumParams) return 0.0;
        return bridge->params[id].load(std::memory_order_relaxed);
    }

    tresult PLUGIN_API setParamNormalized(ParamID id, ParamValue value) override {
        if (id >= kNumParams) return kInvalidArgument;
        bridge->params[id].store(static_cast<float>(std::clamp(value, 0.0, 1.0)), std::memory_order_relaxed);
        return kResultOk;
    }

    tresult PLUGIN_API setComponentHandler(IComponentHandler* handler) override {
        componentHandler = handler;
        return kResultOk;
    }

    IPlugView* PLUGIN_API createView(FIDString name) override {
        if (name && std::strcmp(name, ViewType::kEditor) == 0) {
            return new PixelBlazePlugView(bridge.get(), this);
        }
        return nullptr;
    }

    // --- IMidiMapping (Pitch Bend, Mod Wheel, Sustain Pedal in FL Studio) ---
    tresult PLUGIN_API getMidiControllerAssignment(int32 busIndex, int16 channel,
                                                   CtrlNumber midiControllerNumber, ParamID& id) override {
        (void)busIndex; (void)channel;
        if (midiControllerNumber == kPitchBend) {
            id = kParamPitchBend;
            return kResultTrue;
        }
        if (midiControllerNumber == kCtrlModWheel) {
            id = kParamModWheel;
            return kResultTrue;
        }
        if (midiControllerNumber == kCtrlSustainOnOff) {
            id = kParamSustainPedal;
            return kResultTrue;
        }
        return kResultFalse;
    }

    // --- IUnitInfo (Exposes the 12 Game Pak Factory Presets to FL Studio) ---
    int32 PLUGIN_API getUnitCount() override { return 1; }
    tresult PLUGIN_API getUnitInfo(int32 unitIndex, UnitInfo& info) override {
        if (unitIndex != 0) return kInvalidArgument;
        info.id = kRootUnitId;
        info.parentUnitId = kNoParentUnitId;
        copyAsciiToString128(info.name, "Root");
        info.programListId = 1;
        return kResultOk;
    }

    int32 PLUGIN_API getProgramListCount() override { return 1; }
    tresult PLUGIN_API getProgramListInfo(int32 listIndex, ProgramListInfo& info) override {
        if (listIndex != 0) return kInvalidArgument;
        info.id = 1;
        copyAsciiToString128(info.name, "Pixel-Blaze 1999 Game Paks");
        info.programCount = kNumPresets;
        return kResultOk;
    }

    tresult PLUGIN_API getProgramName(ProgramListID listId, int32 programIndex, String128 name) override {
        if (listId != 1 || programIndex < 0 || programIndex >= kNumPresets) return kInvalidArgument;
        copyAsciiToString128(name, kFactoryPresets[programIndex].name);
        return kResultOk;
    }

    tresult PLUGIN_API getProgramInfo(ProgramListID listId, int32 programIndex, Steinberg::Vst::CString attributeId, String128 attributeValue) override {
        (void)listId; (void)programIndex; (void)attributeId; (void)attributeValue;
        return kNotImplemented;
    }

    tresult PLUGIN_API hasProgramPitchNames(ProgramListID listId, int32 programIndex) override {
        (void)listId; (void)programIndex;
        return kResultFalse;
    }

    tresult PLUGIN_API getProgramPitchName(ProgramListID listId, int32 programIndex, int16 midiPitch, String128 name) override {
        (void)listId; (void)programIndex; (void)midiPitch; (void)name;
        return kNotImplemented;
    }

    UnitID PLUGIN_API getSelectedUnit() override { return kRootUnitId; }
    tresult PLUGIN_API selectUnit(UnitID unitId) override {
        (void)unitId;
        return kResultOk;
    }

    tresult PLUGIN_API getUnitByBus(MediaType type, BusDirection dir, int32 busIndex, int32 channel, UnitID& unitId) override {
        (void)type; (void)dir; (void)busIndex; (void)channel;
        unitId = kRootUnitId;
        return kResultOk;
    }

    tresult PLUGIN_API setUnitProgramData(int32 listOrUnitId, int32 programIndex, IBStream* data) override {
        (void)listOrUnitId; (void)programIndex; (void)data;
        return kNotImplemented;
    }

    // --- IConnectionPoint ---
    tresult PLUGIN_API connect(IConnectionPoint* other) override {
        if (!other) return kInvalidArgument;
        IPixelBlazeBridgeProvider* provider = nullptr;
        if (other->queryInterface(kPixelBlazeBridgeIID, reinterpret_cast<void**>(&provider)) == kResultOk && provider) {
            bridge = provider->getSharedBridge();
            provider->release();
        }
        return kResultOk;
    }

    tresult PLUGIN_API disconnect(IConnectionPoint* other) override {
        (void)other;
        return kResultOk;
    }

    tresult PLUGIN_API notify(IMessage* message) override {
        (void)message;
        return kResultOk;
    }

    // --- IEditorParamCallback ---
    void onGuiBeginEdit(uint32_t paramId) override {
        if (componentHandler) componentHandler->beginEdit(paramId);
    }

    void onGuiPerformEdit(uint32_t paramId, double normalizedValue) override {
        if (componentHandler) componentHandler->performEdit(paramId, normalizedValue);
    }

    void onGuiEndEdit(uint32_t paramId) override {
        if (componentHandler) componentHandler->endEdit(paramId);
    }

    void onGuiPresetSelected(int presetIndex) override {
        if (!componentHandler) return;
        for (uint32_t p = 0; p < kNumParams; ++p) {
            float val = bridge->params[p].load(std::memory_order_relaxed);
            componentHandler->beginEdit(p);
            componentHandler->performEdit(p, val);
            componentHandler->endEdit(p);
        }
        (void)presetIndex;
    }

private:
    std::atomic<uint32> refCount{1};
    std::shared_ptr<SharedSynthBridge> bridge;
    IComponentHandler* componentHandler = nullptr;
};

// ============================================================================
// VST3 Plugin Factory (IPluginFactory3)
// ============================================================================
class PixelBlazePluginFactory : public IPluginFactory3 {
public:
    tresult PLUGIN_API queryInterface(const TUID _iid, void** obj) override {
        if (FUnknownPrivate::iidEqual(_iid, FUnknown::iid) ||
            FUnknownPrivate::iidEqual(_iid, IPluginFactory::iid) ||
            FUnknownPrivate::iidEqual(_iid, IPluginFactory2::iid) ||
            FUnknownPrivate::iidEqual(_iid, IPluginFactory3::iid)) {
            addRef();
            *obj = static_cast<IPluginFactory3*>(this);
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }

    tresult PLUGIN_API getFactoryInfo(PFactoryInfo* info) override {
        if (!info) return kInvalidArgument;
        std::strncpy(info->vendor, "PixelBlaze Entertainment Corp.", PFactoryInfo::kNameSize - 1);
        std::strncpy(info->url, "https://pixelblaze1999.audio", PFactoryInfo::kURLSize - 1);
        std::strncpy(info->email, "support@pixelblaze1999.audio", PFactoryInfo::kEmailSize - 1);
        info->flags = PFactoryInfo::kUnicode;
        return kResultOk;
    }

    int32 PLUGIN_API countClasses() override { return 2; }

    tresult PLUGIN_API getClassInfo(int32 index, PClassInfo* info) override {
        if (!info) return kInvalidArgument;
        if (index == 0) {
            std::memcpy(info->cid, kPixelBlazeProcessorUID, sizeof(TUID));
            info->cardinality = PClassInfo::kManyInstances;
            std::strncpy(info->category, kVstAudioEffectClass, PClassInfo::kCategorySize - 1);
            std::strncpy(info->name, "Pixel-Blaze 1999", PClassInfo::kNameSize - 1);
            return kResultOk;
        }
        if (index == 1) {
            std::memcpy(info->cid, kPixelBlazeControllerUID, sizeof(TUID));
            info->cardinality = PClassInfo::kManyInstances;
            std::strncpy(info->category, kVstComponentControllerClass, PClassInfo::kCategorySize - 1);
            std::strncpy(info->name, "Pixel-Blaze 1999 Controller", PClassInfo::kNameSize - 1);
            return kResultOk;
        }
        return kInvalidArgument;
    }

    tresult PLUGIN_API getClassInfo2(int32 index, PClassInfo2* info) override {
        if (!info) return kInvalidArgument;
        PClassInfo base{};
        if (getClassInfo(index, &base) != kResultOk) return kInvalidArgument;
        std::memcpy(info->cid, base.cid, sizeof(TUID));
        info->cardinality = base.cardinality;
        std::strncpy(info->category, base.category, PClassInfo::kCategorySize - 1);
        std::strncpy(info->name, base.name, PClassInfo::kNameSize - 1);
        info->classFlags = 0;
        std::strncpy(info->subCategories, "Instrument|Synth", PClassInfo2::kSubCategoriesSize - 1);
        std::strncpy(info->vendor, "PixelBlaze Entertainment Corp.", PClassInfo2::kVendorSize - 1);
        std::strncpy(info->version, "1.0.0", PClassInfo2::kVersionSize - 1);
        std::strncpy(info->sdkVersion, kVstVersionString, PClassInfo2::kVersionSize - 1);
        return kResultOk;
    }

    tresult PLUGIN_API getClassInfoUnicode(int32 index, PClassInfoW* info) override {
        if (!info) return kInvalidArgument;
        PClassInfo2 ci2{};
        if (getClassInfo2(index, &ci2) != kResultOk) return kInvalidArgument;
        std::memcpy(info->cid, ci2.cid, sizeof(TUID));
        info->cardinality = ci2.cardinality;
        std::strncpy(info->category, ci2.category, PClassInfo::kCategorySize - 1);
        copyAsciiToString128(info->name, ci2.name);
        info->classFlags = ci2.classFlags;
        std::strncpy(info->subCategories, ci2.subCategories, PClassInfo2::kSubCategoriesSize - 1);
        copyAsciiToString128(info->vendor, ci2.vendor);
        copyAsciiToString128(info->version, ci2.version);
        copyAsciiToString128(info->sdkVersion, ci2.sdkVersion);
        return kResultOk;
    }

    tresult PLUGIN_API setHostContext(FUnknown* context) override {
        (void)context;
        return kResultOk;
    }

    tresult PLUGIN_API createInstance(FIDString cid, FIDString _iid, void** obj) override {
        if (!cid || !_iid || !obj) return kInvalidArgument;
        *obj = nullptr;

        if (FUnknownPrivate::iidEqual(cid, kPixelBlazeProcessorUID)) {
            auto* proc = new PixelBlazeProcessor();
            tresult res = proc->queryInterface(_iid, obj);
            proc->release();
            return res;
        }
        if (FUnknownPrivate::iidEqual(cid, kPixelBlazeControllerUID)) {
            auto* ctrl = new PixelBlazeController();
            tresult res = ctrl->queryInterface(_iid, obj);
            ctrl->release();
            return res;
        }
        return kNoInterface;
    }
};

} // namespace PixelBlaze

extern "C" {

SMTG_EXPORT_SYMBOL Steinberg::IPluginFactory* PLUGIN_API GetPluginFactory() {
    static PixelBlaze::PixelBlazePluginFactory sFactory;
    return &sFactory;
}

SMTG_EXPORT_SYMBOL bool bundleEntry(CFBundleRef bundle) {
    (void)bundle;
    return true;
}

SMTG_EXPORT_SYMBOL bool bundleExit() {
    return true;
}

} // extern "C"
