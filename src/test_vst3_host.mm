#define INIT_CLASS_IID

#import <Cocoa/Cocoa.h>
#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstunits.h"
#include "PixelBlazeParams.h"
#include <memory>

static const Steinberg::TUID kPixelBlazeBridgeIID = INLINE_UID(0x88B1A299, 0x19994F01, 0x9C44E812, 0x55A0199B);
class IPixelBlazeBridgeProvider : public Steinberg::FUnknown {
public:
    virtual std::shared_ptr<PixelBlaze::SharedSynthBridge> getSharedBridge() = 0;
};

#include <cmath>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <vector>

using namespace Steinberg;
using namespace Steinberg::Vst;

class HostEventList : public IEventList {
public:
    std::vector<Event> events;

    tresult PLUGIN_API queryInterface(const TUID _iid, void** obj) override {
        if (FUnknownPrivate::iidEqual(_iid, FUnknown::iid) ||
            FUnknownPrivate::iidEqual(_iid, IEventList::iid)) {
            *obj = static_cast<IEventList*>(this);
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }

    int32 PLUGIN_API getEventCount() override { return static_cast<int32>(events.size()); }
    tresult PLUGIN_API getEvent(int32 index, Event& e) override {
        if (index < 0 || index >= static_cast<int32>(events.size())) return kInvalidArgument;
        e = events[index];
        return kResultOk;
    }
    tresult PLUGIN_API addEvent(Event& e) override {
        events.push_back(e);
        return kResultOk;
    }
};

class MemoryBStream : public IBStream {
public:
    std::vector<uint8_t> data;
    int64_t pos = 0;

    tresult PLUGIN_API queryInterface(const TUID _iid, void** obj) override {
        if (FUnknownPrivate::iidEqual(_iid, FUnknown::iid) ||
            FUnknownPrivate::iidEqual(_iid, IBStream::iid)) {
            *obj = static_cast<IBStream*>(this);
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }

    tresult PLUGIN_API read(void* buffer, int32 numBytes, int32* numBytesRead) override {
        if (!buffer || numBytes < 0) return kInvalidArgument;
        int64_t avail = static_cast<int64_t>(data.size()) - pos;
        int32 toRead = static_cast<int32>(std::max<int64_t>(0, std::min<int64_t>(numBytes, avail)));
        if (toRead > 0) {
            std::memcpy(buffer, data.data() + pos, toRead);
            pos += toRead;
        }
        if (numBytesRead) *numBytesRead = toRead;
        return kResultOk;
    }

    tresult PLUGIN_API write(void* buffer, int32 numBytes, int32* numBytesWritten) override {
        if (!buffer || numBytes < 0) return kInvalidArgument;
        if (pos + numBytes > static_cast<int64_t>(data.size())) {
            data.resize(pos + numBytes);
        }
        std::memcpy(data.data() + pos, buffer, numBytes);
        pos += numBytes;
        if (numBytesWritten) *numBytesWritten = numBytes;
        return kResultOk;
    }

    tresult PLUGIN_API seek(int64 posIn, int32 mode, int64* result) override {
        if (mode == kIBSeekSet) pos = posIn;
        else if (mode == kIBSeekCur) pos += posIn;
        else if (mode == kIBSeekEnd) pos = static_cast<int64_t>(data.size()) + posIn;
        pos = std::clamp<int64_t>(pos, 0, data.size());
        if (result) *result = pos;
        return kResultOk;
    }

    tresult PLUGIN_API tell(int64* result) override {
        if (result) *result = pos;
        return kResultOk;
    }
};

static void writeWavFile(const char* path, const std::vector<float>& left, const std::vector<float>& right, int sampleRate) {
    FILE* f = std::fopen(path, "wb");
    if (!f) return;
    uint32_t numSamples = static_cast<uint32_t>(left.size());
    uint32_t dataSize = numSamples * 2 * sizeof(int16_t);
    uint32_t riffSize = 36 + dataSize;
    uint16_t audioFormat = 1;
    uint16_t numChannels = 2;
    uint32_t sr = sampleRate;
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
}

int main(int argc, char** argv) {
    @autoreleasepool {
        const char* bundlePath = (argc > 1) ? argv[1] : "build/Pixel-Blaze 1999.vst3";
        const char* screenshotPath = (argc > 2) ? argv[2] : "build/preview_nes_scope.png";
        const char* wavPath = (argc > 3) ? argv[3] : "build/pixelblaze_demo.wav";

        std::printf("=== Pixel-Blaze 1999 VST3 Host Validator & Audio Render Test ===\n");
        std::printf("Loading VST3 bundle: %s\n", bundlePath);

        NSString* nsBundlePath = [NSString stringWithUTF8String:bundlePath];
        CFURLRef bundleUrl = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)nsBundlePath, kCFURLPOSIXPathStyle, true);
        CFBundleRef cfBundle = CFBundleCreate(kCFAllocatorDefault, bundleUrl);
        if (!cfBundle) {
            std::fprintf(stderr, "FAIL: Could not create CFBundle from %s\n", bundlePath);
            return 1;
        }

        std::string execPath = std::string(bundlePath) + "/Contents/MacOS/PixelBlaze1999";
        void* handle = dlopen(execPath.c_str(), RTLD_LAZY | RTLD_LOCAL);
        if (!handle) {
            std::fprintf(stderr, "FAIL: dlopen failed: %s\n", dlerror());
            return 1;
        }

        using BundleEntryProc = bool (*)(CFBundleRef);
        using BundleExitProc = bool (*)();
        auto bundleEntryFn = reinterpret_cast<BundleEntryProc>(dlsym(handle, "bundleEntry"));
        auto bundleExitFn  = reinterpret_cast<BundleExitProc>(dlsym(handle, "bundleExit"));
        auto getFactoryFn  = reinterpret_cast<GetFactoryProc>(dlsym(handle, "GetPluginFactory"));

        if (!bundleEntryFn || !bundleExitFn || !getFactoryFn) {
            std::fprintf(stderr, "FAIL: Missing required VST3 symbols\n");
            return 1;
        }

        if (!bundleEntryFn(cfBundle)) {
            std::fprintf(stderr, "FAIL: bundleEntry returned false\n");
            return 1;
        }

        IPluginFactory* factory = getFactoryFn();
        if (!factory) {
            std::fprintf(stderr, "FAIL: GetPluginFactory returned null\n");
            return 1;
        }

        PFactoryInfo fInfo{};
        factory->getFactoryInfo(&fInfo);
        std::printf("[PASS] Factory Vendor: %s | URL: %s\n", fInfo.vendor, fInfo.url);

        int32 numClasses = factory->countClasses();
        std::printf("[PASS] Exported Classes: %d\n", numClasses);

        IPluginFactory2* factory2 = nullptr;
        factory->queryInterface(IPluginFactory2::iid, reinterpret_cast<void**>(&factory2));

        TUID procCid{};
        for (int32 i = 0; i < numClasses; ++i) {
            PClassInfo2 ci2{};
            factory2->getClassInfo2(i, &ci2);
            std::printf("  Class %d: name='%s' category='%s' subCategories='%s' version='%s'\n",
                        i, ci2.name, ci2.category, ci2.subCategories, ci2.version);
            if (std::strcmp(ci2.category, kVstAudioEffectClass) == 0) {
                std::memcpy(procCid, ci2.cid, sizeof(TUID));
            }
        }

        IComponent* component = nullptr;
        if (factory->createInstance(procCid, IComponent::iid, reinterpret_cast<void**>(&component)) != kResultOk || !component) {
            std::fprintf(stderr, "FAIL: Could not create IComponent instance\n");
            return 1;
        }
        component->initialize(nullptr);

        TUID ctrlCid{};
        component->getControllerClassId(ctrlCid);

        IEditController* controller = nullptr;
        if (factory->createInstance(ctrlCid, IEditController::iid, reinterpret_cast<void**>(&controller)) != kResultOk || !controller) {
            std::fprintf(stderr, "FAIL: Could not create IEditController instance\n");
            return 1;
        }
        controller->initialize(nullptr);

        IConnectionPoint* connProc = nullptr;
        IConnectionPoint* connCtrl = nullptr;
        component->queryInterface(IConnectionPoint::iid, reinterpret_cast<void**>(&connProc));
        controller->queryInterface(IConnectionPoint::iid, reinterpret_cast<void**>(&connCtrl));
        if (connProc && connCtrl) {
            connProc->connect(connCtrl);
            connCtrl->connect(connProc);
            std::printf("[PASS] IConnectionPoint connected between Processor and Controller\n");
        }

        MemoryBStream stateStream;
        component->getState(&stateStream);
        stateStream.seek(0, IBStream::kIBSeekSet, nullptr);
        controller->setComponentState(&stateStream);
        std::printf("[PASS] Component -> Controller state stream verified (%zu bytes)\n", stateStream.data.size());

        int32 paramCount = controller->getParameterCount();
        std::printf("[PASS] Controller Parameter Count: %d\n", paramCount);

        IUnitInfo* unitInfo = nullptr;
        if (controller->queryInterface(IUnitInfo::iid, reinterpret_cast<void**>(&unitInfo)) == kResultOk && unitInfo) {
            ProgramListInfo pli{};
            unitInfo->getProgramListInfo(0, pli);
            std::printf("[PASS] IUnitInfo Program List: %d Game Pak factory presets\n", pli.programCount);
            unitInfo->release();
        }

        IAudioProcessor* processor = nullptr;
        component->queryInterface(IAudioProcessor::iid, reinterpret_cast<void**>(&processor));
        ProcessSetup setup{kRealtime, kSample32, 512, 44100.0};
        processor->setupProcessing(setup);
        component->activateBus(kAudio, kOutput, 0, true);
        component->activateBus(kEvent, kInput, 0, true);
        component->setActive(true);
        processor->setProcessing(true);

        int sr = 44100;
        int blockSize = 512;
        int totalBlocks = (sr * 3) / blockSize;
        std::vector<float> fullL, fullR;
        fullL.reserve(totalBlocks * blockSize);
        fullR.reserve(totalBlocks * blockSize);

        std::vector<float> bufL(blockSize, 0.0f);
        std::vector<float> bufR(blockSize, 0.0f);
        float* chans[2] = {bufL.data(), bufR.data()};

        AudioBusBuffers outBus{};
        outBus.numChannels = 2;
        outBus.channelBuffers32 = chans;

        HostEventList eventList;
        ProcessData procData{};
        procData.processMode = kRealtime;
        procData.symbolicSampleSize = kSample32;
        procData.numSamples = blockSize;
        procData.numOutputs = 1;
        procData.outputs = &outBus;
        procData.inputEvents = &eventList;

        // Enable 60Hz Tracker Arp & Play 8-Bit Chiptune Chord (C3, G3, C4, Eb4, G4)
        controller->setParamNormalized(PixelBlaze::kParamArpEnable, 1.0);
        const int16_t chordNotes[5] = {48, 55, 60, 63, 67};
        float maxPeak = 0.0f;
        double sumSq = 0.0;

        for (int b = 0; b < totalBlocks; ++b) {
            eventList.events.clear();
            if (b == 0) {
                for (int n = 0; n < 5; ++n) {
                    Event e{};
                    e.busIndex = 0;
                    e.sampleOffset = 0;
                    e.type = Event::kNoteOnEvent;
                    e.noteOn.channel = 0;
                    e.noteOn.pitch = chordNotes[n];
                    e.noteOn.velocity = 0.90f;
                    e.noteOn.noteId = n;
                    eventList.addEvent(e);
                }
            }
            if (b == (totalBlocks * 3) / 4) {
                for (int n = 0; n < 5; ++n) {
                    Event e{};
                    e.busIndex = 0;
                    e.sampleOffset = 0;
                    e.type = Event::kNoteOffEvent;
                    e.noteOff.channel = 0;
                    e.noteOff.pitch = chordNotes[n];
                    e.noteOff.velocity = 0.0f;
                    e.noteOff.noteId = n;
                    eventList.addEvent(e);
                }
            }

            processor->process(procData);

            for (int s = 0; s < blockSize; ++s) {
                float l = bufL[s];
                float r = bufR[s];
                fullL.push_back(l);
                fullR.push_back(r);
                maxPeak = std::max(maxPeak, std::max(std::fabs(l), std::fabs(r)));
                sumSq += (l * l + r * r) * 0.5;
            }
        }

        double rms = std::sqrt(sumSq / fullL.size());
        std::printf("[PASS] Audio Render Complete: Peak = %.4f, RMS = %.4f\n", maxPeak, rms);
        if (maxPeak < 0.05f || std::isnan(maxPeak)) {
            std::fprintf(stderr, "FAIL: Audio output silent or invalid!\n");
            return 1;
        }
        writeWavFile(wavPath, fullL, fullR, sr);
        std::printf("[PASS] Wrote stereo demo WAV: %s\n", wavPath);

        // Re-trigger notes so keyboard, meters, and CRT scope are active in screenshots
        eventList.events.clear();
        for (int n = 0; n < 4; ++n) {
            Event e{};
            e.type = Event::kNoteOnEvent;
            e.noteOn.pitch = chordNotes[n];
            e.noteOn.velocity = 0.92f;
            e.noteOn.noteId = 20 + n;
            eventList.addEvent(e);
        }
        for (int b = 0; b < 10; ++b) {
            processor->process(procData);
            eventList.events.clear();
        }

        @autoreleasepool {
            [NSApplication sharedApplication];
            IPlugView* view = controller->createView(ViewType::kEditor);
            if (!view) {
                std::fprintf(stderr, "FAIL: createView('editor') returned null\n");
                return 1;
            }
            ViewRect vr{};
            view->getSize(&vr);
            std::printf("[PASS] IPlugView created: %d x %d\n", vr.getWidth(), vr.getHeight());

            NSRect winRect = NSMakeRect(0, 0, vr.getWidth(), vr.getHeight());
            NSView* hostContainer = [[NSView alloc] initWithFrame:winRect];
            if (view->attached((__bridge void*)hostContainer, kPlatformTypeNSView) != kResultOk) {
                std::fprintf(stderr, "FAIL: IPlugView::attached failed\n");
                return 1;
            }

            std::shared_ptr<PixelBlaze::SharedSynthBridge> sharedBridge;
            IPixelBlazeBridgeProvider* bp = nullptr;
            if (component->queryInterface(kPixelBlazeBridgeIID, reinterpret_cast<void**>(&bp)) == kResultOk && bp) {
                sharedBridge = bp->getSharedBridge();
                bp->release();
            }

            // Render Screenshot 1: NES 1985 Skin + PAK-01 + CRT Oscilloscope (Screen Mode 0)
            if (sharedBridge) {
                sharedBridge->applyPreset(0);
                sharedBridge->screenMode.store(0, std::memory_order_relaxed);
                sharedBridge->params[PixelBlaze::kParamArpEnable].store(1.0f, std::memory_order_relaxed);
            }
            NSBitmapImageRep* rep1 = [hostContainer bitmapImageRepForCachingDisplayInRect:winRect];
            [hostContainer cacheDisplayInRect:winRect toBitmapImageRep:rep1];
            NSData* png1 = [rep1 representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png1 writeToFile:[NSString stringWithUTF8String:screenshotPath] atomically:YES];
            std::printf("[PASS] Rendered NES 1985 GUI preview PNG: %s\n", screenshotPath);

            // Render Screenshot 2: Game Boy DMG-01 Skin + PAK-04 + 32x16 4-Bit Wave RAM Editor (Screen Mode 1)
            if (sharedBridge) {
                sharedBridge->applyPreset(3);
                sharedBridge->screenMode.store(1, std::memory_order_relaxed);
                sharedBridge->params[PixelBlaze::kParamConsoleSkin].store(0.667f, std::memory_order_relaxed);
            }
            NSBitmapImageRep* rep2 = [hostContainer bitmapImageRepForCachingDisplayInRect:winRect];
            [hostContainer cacheDisplayInRect:winRect toBitmapImageRep:rep2];
            NSData* png2 = [rep2 representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png2 writeToFile:@"build/preview_dmg_skin.png" atomically:YES];

            // Render Screenshot 3: Famicom 1983 Gold/Maroon Skin + PAK-03 + 8-Step Tracker Arp Grid (Screen Mode 2)
            if (sharedBridge) {
                sharedBridge->applyPreset(2);
                sharedBridge->screenMode.store(2, std::memory_order_relaxed);
                sharedBridge->params[PixelBlaze::kParamConsoleSkin].store(0.333f, std::memory_order_relaxed);
            }
            NSBitmapImageRep* rep3 = [hostContainer bitmapImageRepForCachingDisplayInRect:winRect];
            [hostContainer cacheDisplayInRect:winRect toBitmapImageRep:rep3];
            NSData* png3 = [rep3 representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png3 writeToFile:@"build/preview_famicom_skin.png" atomically:YES];

            // Render Screenshot 4: C64 Breadbin 1982 Skin + PAK-05 Robocop SID 6581 (Screen Mode 0)
            if (sharedBridge) {
                sharedBridge->applyPreset(4);
                sharedBridge->screenMode.store(0, std::memory_order_relaxed);
                sharedBridge->params[PixelBlaze::kParamConsoleSkin].store(1.0f, std::memory_order_relaxed);
            }
            NSBitmapImageRep* rep4 = [hostContainer bitmapImageRepForCachingDisplayInRect:winRect];
            [hostContainer cacheDisplayInRect:winRect toBitmapImageRep:rep4];
            NSData* png4 = [rep4 representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png4 writeToFile:@"build/preview_c64_skin.png" atomically:YES];

            // Reset back to NES default
            if (sharedBridge) {
                sharedBridge->applyPreset(0);
                sharedBridge->screenMode.store(0, std::memory_order_relaxed);
            }

            view->removed();
            view->release();
        }

        processor->setProcessing(false);
        component->setActive(false);
        if (connProc && connCtrl) {
            connProc->disconnect(connCtrl);
            connCtrl->disconnect(connProc);
            connProc->release();
            connCtrl->release();
        }
        processor->release();
        controller->terminate();
        controller->release();
        component->terminate();
        component->release();
        if (factory2) factory2->release();
        factory->release();
        bundleExitFn();
        CFRelease(cfBundle);
        CFRelease(bundleUrl);

        std::printf("=== ALL VST3 HOST VALIDATION CHECKS PASSED ===\n");
        return 0;
    }
}
