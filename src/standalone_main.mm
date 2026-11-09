#define INIT_CLASS_IID

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMIDI/CoreMIDI.h>
#include "PixelBlazeParams.h"
#include "ChipEngine.h"
#include "PixelBlazeGUI.h"
#include <atomic>
#include <cstdio>
#include <mutex>
#include <vector>

namespace {

struct StandaloneAudioContext {
    PixelBlaze::SharedSynthBridge bridge;
    PixelBlaze::ChipEngine engine;
    AudioQueueRef queue = nullptr;
    AudioQueueBufferRef buffers[3] = {nullptr, nullptr, nullptr};
    static constexpr int kFramesPerBuffer = 256;
    float tempL[kFramesPerBuffer];
    float tempR[kFramesPerBuffer];

    // Live WAV Recorder state
    std::atomic<bool> prevConsoleRecFlag{false};
    std::mutex recMutex;
    std::vector<float> recLeft;
    std::vector<float> recRight;
    std::atomic<bool> pendingSaveDialog{false};

    // Built-in 8-Bit Arcade Chiptune Demo Sequencer
    std::atomic<bool> isDemoPlaying{false};
    uint64_t demoSampleCounter = 0;
    int currentStepIdx = -1;

    // CoreMIDI Client
    MIDIClientRef midiClient = 0;
    MIDIPortRef midiInPort = 0;
    int connectedMidiSources = 0;
};

// 16-Step 8-Bit Chiptune Hero Melody + Bassline (C Minor / Eb Major Arcade Anthem)
static const int16_t kDemoMelody[16] = {
    72, 75, 79, 84,  82, 79, 75, 72,
    70, 74, 77, 82,  79, 75, 74, 79
};
static const int16_t kDemoBass[16] = {
    48, 60, 48, 60,  44, 56, 44, 56,
    46, 58, 46, 58,  43, 55, 47, 59
};

static void audioQueueOutputCallback(void* inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    auto* ctx = static_cast<StandaloneAudioContext*>(inUserData);
    int frames = StandaloneAudioContext::kFramesPerBuffer;

    if (ctx->isDemoPlaying.load(std::memory_order_relaxed)) {
        const uint64_t samplesPerStep = 5512; // ~125ms per 16th note (120 BPM)
        uint64_t posInStep = ctx->demoSampleCounter % samplesPerStep;
        int stepIdx = static_cast<int>((ctx->demoSampleCounter / samplesPerStep) % 16);

        if (stepIdx != ctx->currentStepIdx) {
            if (ctx->currentStepIdx >= 0) {
                ctx->engine.noteOff(kDemoMelody[ctx->currentStepIdx], -1, &ctx->bridge);
                ctx->engine.noteOff(kDemoBass[ctx->currentStepIdx], -1, &ctx->bridge);
            }
            ctx->currentStepIdx = stepIdx;
            ctx->engine.noteOn(kDemoMelody[stepIdx], 0.88f, -1, &ctx->bridge);
            ctx->engine.noteOn(kDemoBass[stepIdx], 0.82f, -1, &ctx->bridge);
        } else if (posInStep >= (samplesPerStep * 3) / 4 && posInStep < (samplesPerStep * 3) / 4 + frames) {
            ctx->engine.noteOff(kDemoMelody[stepIdx], -1, &ctx->bridge);
            ctx->engine.noteOff(kDemoBass[stepIdx], -1, &ctx->bridge);
        }
        ctx->demoSampleCounter += frames;
    } else if (ctx->currentStepIdx >= 0) {
        ctx->engine.noteOff(kDemoMelody[ctx->currentStepIdx], -1, &ctx->bridge);
        ctx->engine.noteOff(kDemoBass[ctx->currentStepIdx], -1, &ctx->bridge);
        ctx->currentStepIdx = -1;
    }

    ctx->engine.processBlock(ctx->tempL, ctx->tempR, frames, &ctx->bridge);

    float* outInterleaved = static_cast<float*>(inBuffer->mAudioData);
    for (int i = 0; i < frames; ++i) {
        outInterleaved[i * 2 + 0] = ctx->tempL[i];
        outInterleaved[i * 2 + 1] = ctx->tempR[i];
    }

    bool recNow = ctx->bridge.isRecordingWav.load(std::memory_order_relaxed);
    bool recPrev = ctx->prevConsoleRecFlag.exchange(recNow, std::memory_order_relaxed);
    if (recNow) {
        std::lock_guard<std::mutex> lock(ctx->recMutex);
        for (int i = 0; i < frames; ++i) {
            ctx->recLeft.push_back(ctx->tempL[i]);
            ctx->recRight.push_back(ctx->tempR[i]);
        }
    } else if (recPrev && !recNow) {
        ctx->pendingSaveDialog.store(true, std::memory_order_relaxed);
    }

    inBuffer->mAudioDataByteSize = frames * 2 * sizeof(float);
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nullptr);
}

static void midiReadProc(const MIDIPacketList* pktlist, void* readProcRefCon, void* srcConnRefCon) {
    (void)srcConnRefCon;
    auto* ctx = static_cast<StandaloneAudioContext*>(readProcRefCon);
    if (!ctx || !pktlist) return;

    const MIDIPacket* packet = &pktlist->packet[0];
    for (UInt32 i = 0; i < pktlist->numPackets; ++i) {
        const Byte* data = packet->data;
        UInt16 len = packet->length;
        UInt16 idx = 0;
        while (idx < len) {
            Byte status = data[idx];
            Byte cmd = status & 0xF0;
            if (cmd == 0x90 && idx + 2 < len) {
                int pitch = data[idx + 1] & 0x7F;
                int velByte = data[idx + 2] & 0x7F;
                if (velByte > 0) {
                    ctx->bridge.pushUiNoteEvent(static_cast<int16_t>(pitch), static_cast<float>(velByte) / 127.0f, true);
                } else {
                    ctx->bridge.pushUiNoteEvent(static_cast<int16_t>(pitch), 0.0f, false);
                }
                idx += 3;
            } else if (cmd == 0x80 && idx + 2 < len) {
                int pitch = data[idx + 1] & 0x7F;
                ctx->bridge.pushUiNoteEvent(static_cast<int16_t>(pitch), 0.0f, false);
                idx += 3;
            } else if (cmd == 0xB0 && idx + 2 < len) {
                int cc = data[idx + 1] & 0x7F;
                float val = static_cast<float>(data[idx + 2] & 0x7F) / 127.0f;
                if (cc == 64) {
                    ctx->bridge.params[PixelBlaze::kParamSustainPedal].store(val >= 0.5f ? 1.0f : 0.0f, std::memory_order_relaxed);
                } else if (cc == 1) {
                    ctx->bridge.params[PixelBlaze::kParamModWheel].store(val, std::memory_order_relaxed);
                } else if (cc == 7) {
                    ctx->bridge.params[PixelBlaze::kParamMasterVolume].store(val, std::memory_order_relaxed);
                }
                idx += 3;
            } else if (cmd == 0xE0 && idx + 2 < len) {
                int lsb = data[idx + 1] & 0x7F;
                int msb = data[idx + 2] & 0x7F;
                int bend14 = (msb << 7) | lsb;
                float norm = static_cast<float>(bend14) / 16383.0f;
                ctx->bridge.params[PixelBlaze::kParamPitchBend].store(norm, std::memory_order_relaxed);
                idx += 3;
            } else {
                idx++;
            }
        }
        packet = MIDIPacketNext(packet);
    }
}

static bool writeStereoWavFile(const char* path, const std::vector<float>& left, const std::vector<float>& right, int sampleRate) {
    FILE* f = std::fopen(path, "wb");
    if (!f) return false;
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
    return true;
}

static constexpr uint32_t kPatchFileMagic = 0x50423939; // 'PB99'

} // namespace

@interface PixelBlazeStandaloneAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate> {
    NSWindow* _window;
    NSView* _containerView;
    StandaloneAudioContext* _audioCtx;
    void* _editorViewPtr;
    NSButton* _demoBtn;
    NSButton* _recBtn;
    NSTextField* _statusLabel;
    NSTimer* _uiPollTimer;
}
@end

@implementation PixelBlazeStandaloneAppDelegate

- (void)setupMainMenu {
    NSMenu* mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    [NSApp setMainMenu:mainMenu];

    NSMenuItem* appMenuItem = [[NSMenuItem alloc] initWithTitle:@"Pixel-Blaze 1999" action:nil keyEquivalent:@""];
    [mainMenu addItem:appMenuItem];
    NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"Pixel-Blaze 1999"];
    [appMenuItem setSubmenu:appMenu];

    [appMenu addItemWithTitle:@"About Pixel-Blaze 1999" action:@selector(showAboutDialog:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Pixel-Blaze 1999" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit Pixel-Blaze 1999" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenuItem* fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"Cartridge" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileMenuItem];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"Cartridge"];
    [fileMenuItem setSubmenu:fileMenu];

    [fileMenu addItemWithTitle:@"Save Game Pak Patch (.pb99)..." action:@selector(savePatchAction:) keyEquivalent:@"s"];
    [fileMenu addItemWithTitle:@"Load Game Pak Patch (.pb99)..." action:@selector(loadPatchAction:) keyEquivalent:@"o"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Start / Stop WAV Recording" action:@selector(toggleRecordAction:) keyEquivalent:@"r"];
    [fileMenu addItemWithTitle:@"Play / Stop 8-Bit Arcade Demo" action:@selector(toggleDemoAction:) keyEquivalent:@"d"];

    NSMenuItem* presetsMenuItem = [[NSMenuItem alloc] initWithTitle:@"Game Paks" action:nil keyEquivalent:@""];
    [mainMenu addItem:presetsMenuItem];
    NSMenu* presetsMenu = [[NSMenu alloc] initWithTitle:@"Game Paks"];
    [presetsMenuItem setSubmenu:presetsMenu];

    for (int i = 0; i < PixelBlaze::kNumPresets; ++i) {
        NSString* title = [NSString stringWithFormat:@"%s: %s", PixelBlaze::kFactoryPresets[i].code, PixelBlaze::kFactoryPresets[i].name];
        NSString* keyEq = (i < 9) ? [NSString stringWithFormat:@"%d", i + 1] : @"";
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectMenuPreset:) keyEquivalent:keyEq];
        [item setTag:i];
        [presetsMenu addItem:item];
    }
}

- (void)setupCoreMIDI {
    if (MIDIClientCreate(CFSTR("PixelBlaze1999 MIDI Client"), nullptr, nullptr, &_audioCtx->midiClient) == noErr) {
        if (MIDIInputPortCreate(_audioCtx->midiClient, CFSTR("PixelBlaze1999 MIDI Input"), midiReadProc, _audioCtx, &_audioCtx->midiInPort) == noErr) {
            ItemCount numSources = MIDIGetNumberOfSources();
            for (ItemCount i = 0; i < numSources; ++i) {
                MIDIEndpointRef src = MIDIGetSource(i);
                if (src) {
                    MIDIPortConnectSource(_audioCtx->midiInPort, src, nullptr);
                    _audioCtx->connectedMidiSources++;
                }
            }
        }
    }
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    _audioCtx = new StandaloneAudioContext();
    _audioCtx->engine.setSampleRate(44100.0f);

    [self setupMainMenu];
    [self setupCoreMIDI];

    AudioStreamBasicDescription fmt{};
    fmt.mSampleRate = 44100.0;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mBytesPerPacket = 2 * sizeof(float);
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = 2 * sizeof(float);
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel = 32;

    if (AudioQueueNewOutput(&fmt, audioQueueOutputCallback, _audioCtx, nullptr, kCFRunLoopCommonModes, 0, &_audioCtx->queue) == noErr) {
        UInt32 bufBytes = StandaloneAudioContext::kFramesPerBuffer * 2 * sizeof(float);
        for (int i = 0; i < 3; ++i) {
            AudioQueueAllocateBuffer(_audioCtx->queue, bufBytes, &_audioCtx->buffers[i]);
            audioQueueOutputCallback(_audioCtx, _audioCtx->queue, _audioCtx->buffers[i]);
        }
        AudioQueueStart(_audioCtx->queue, nullptr);
    }

    int editorW = PixelBlaze::PixelBlazePlugView::kDefaultWidth;
    int editorH = PixelBlaze::PixelBlazePlugView::kDefaultHeight;
    int toolbarH = 38;

    NSRect frame = NSMakeRect(80, 80, editorW, editorH + toolbarH);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:style
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:@"PIXEL-BLAZE 1999 — Authentic 8-Bit Video Game Console Synthesizer (NES 2A03 / DMG-01 / SID 6581 / SN76489)"];
    [_window setBackgroundColor:[NSColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0]];
    [_window setDelegate:self];

    _containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, editorW, editorH + toolbarH)];
    [_window setContentView:_containerView];

    _editorViewPtr = PixelBlaze::createStandaloneEditorNsView(&_audioCtx->bridge, nullptr, editorW, editorH);
    NSView* editorView = (__bridge NSView*)_editorViewPtr;
    [editorView setFrame:NSMakeRect(0, 0, editorW, editorH)];
    [_containerView addSubview:editorView];

    // Top Desktop Studio Utility Bar
    NSView* topBar = [[NSView alloc] initWithFrame:NSMakeRect(0, editorH, editorW, toolbarH)];
    [topBar setWantsLayer:YES];
    topBar.layer.backgroundColor = [[NSColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0] CGColor];
    [_containerView addSubview:topBar];

    _demoBtn = [[NSButton alloc] initWithFrame:NSMakeRect(14, 6, 178, 26)];
    [_demoBtn setTitle:@"▶ Play 8-Bit Arcade Demo"];
    [_demoBtn setBezelStyle:NSBezelStyleRounded];
    [_demoBtn setTarget:self];
    [_demoBtn setAction:@selector(toggleDemoAction:)];
    [topBar addSubview:_demoBtn];

    _recBtn = [[NSButton alloc] initWithFrame:NSMakeRect(198, 6, 156, 26)];
    [_recBtn setTitle:@"● Record Audio (WAV)"];
    [_recBtn setBezelStyle:NSBezelStyleRounded];
    [_recBtn setTarget:self];
    [_recBtn setAction:@selector(toggleRecordAction:)];
    [topBar addSubview:_recBtn];

    NSButton* saveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(360, 6, 112, 26)];
    [saveBtn setTitle:@"Save Game Pak..."];
    [saveBtn setBezelStyle:NSBezelStyleRounded];
    [saveBtn setTarget:self];
    [saveBtn setAction:@selector(savePatchAction:)];
    [topBar addSubview:saveBtn];

    NSButton* loadBtn = [[NSButton alloc] initWithFrame:NSMakeRect(478, 6, 112, 26)];
    [loadBtn setTitle:@"Load Game Pak..."];
    [loadBtn setBezelStyle:NSBezelStyleRounded];
    [loadBtn setTarget:self];
    [loadBtn setAction:@selector(loadPatchAction:)];
    [topBar addSubview:loadBtn];

    NSButton* panicBtn = [[NSButton alloc] initWithFrame:NSMakeRect(596, 6, 76, 26)];
    [panicBtn setTitle:@"Panic!"];
    [panicBtn setBezelStyle:NSBezelStyleRounded];
    [panicBtn setTarget:self];
    [panicBtn setAction:@selector(panicAction:)];
    [topBar addSubview:panicBtn];

    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(682, 9, editorW - 694, 18)];
    [_statusLabel setEditable:NO];
    [_statusLabel setBordered:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setTextColor:[NSColor colorWithRed:0.35 green:0.95 blue:0.65 alpha:1.0]];
    [_statusLabel setFont:[NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightMedium]];
    [_statusLabel setAlignment:NSTextAlignmentRight];
    [_statusLabel setStringValue:[NSString stringWithFormat:@"CoreAudio 44.1kHz | MIDI In: %d | QWERTY Keys Active", _audioCtx->connectedMidiSources]];
    [topBar addSubview:_statusLabel];

    _uiPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                    target:self
                                                  selector:@selector(pollRecordingState:)
                                                  userInfo:nil
                                                   repeats:YES];

    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:editorView];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)pollRecordingState:(NSTimer*)timer {
    (void)timer;
    if (!_audioCtx) return;
    bool recNow = _audioCtx->bridge.isRecordingWav.load(std::memory_order_relaxed);
    [_recBtn setTitle:(recNow ? @"■ Stop & Save WAV..." : @"● Record Audio (WAV)")];

    if (_audioCtx->pendingSaveDialog.exchange(false, std::memory_order_relaxed)) {
        [self promptSaveRecordedWav];
    }
}

- (void)promptSaveRecordedWav {
    std::vector<float> copyL, copyR;
    {
        std::lock_guard<std::mutex> lock(_audioCtx->recMutex);
        copyL.swap(_audioCtx->recLeft);
        copyR.swap(_audioCtx->recRight);
    }
    if (copyL.empty()) return;

    NSSavePanel* panel = [NSSavePanel savePanel];
    [panel setTitle:@"Save Pixel-Blaze 1999 Recorded Audio (16-Bit Stereo WAV)"];
    [panel setNameFieldStringValue:@"PixelBlaze1999_Recording.wav"];
    if ([panel runModal] == NSModalResponseOK && [panel URL]) {
        const char* path = [[[panel URL] path] UTF8String];
        if (writeStereoWavFile(path, copyL, copyR, 44100)) {
            [_statusLabel setStringValue:[NSString stringWithFormat:@"Saved WAV (%zu frames)", copyL.size()]];
        }
    }
}

- (void)showAboutDialog:(id)sender {
    (void)sender;
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"PIXEL-BLAZE 1999 (v1.0.0)"];
    [alert setInformativeText:@"Super Authentic 8-Bit Video Game Console VST3 & Standalone Synthesizer.\n\n• 4 Sound Chips: NES 2A03, Game Boy DMG-01, C64 SID 6581, Sega SN76489\n• Interactive 32x16 4-Bit Wavetable Drawer & 8-Step 60Hz Tracker Arp\n• Physical D-Pad X/Y Modulator, B (Glitch Randomizer) & A (Fire) Arcade Buttons\n• 4 Console Hardware Skins & 12 Game Pak Cartridges"];
    [alert runModal];
}

- (void)selectMenuPreset:(NSMenuItem*)sender {
    int idx = static_cast<int>([sender tag]);
    if (idx >= 0 && idx < PixelBlaze::kNumPresets) {
        _audioCtx->bridge.applyPreset(idx);
        [_statusLabel setStringValue:[NSString stringWithFormat:@"Inserted %s: %s",
            PixelBlaze::kFactoryPresets[idx].code, PixelBlaze::kFactoryPresets[idx].name]];
    }
}

- (void)toggleDemoAction:(id)sender {
    (void)sender;
    bool nowPlaying = !_audioCtx->isDemoPlaying.load(std::memory_order_relaxed);
    _audioCtx->demoSampleCounter = 0;
    _audioCtx->isDemoPlaying.store(nowPlaying, std::memory_order_relaxed);
    if (nowPlaying) {
        [_demoBtn setTitle:@"■ Stop 8-Bit Arcade Demo"];
        [_statusLabel setStringValue:@"Playing 8-Bit Arcade Chiptune Demo..."];
    } else {
        [_demoBtn setTitle:@"▶ Play 8-Bit Arcade Demo"];
        [_statusLabel setStringValue:@"Demo Stopped"];
    }
}

- (void)toggleRecordAction:(id)sender {
    (void)sender;
    bool currentlyRec = _audioCtx->bridge.isRecordingWav.load(std::memory_order_relaxed);
    if (!currentlyRec) {
        {
            std::lock_guard<std::mutex> lock(_audioCtx->recMutex);
            _audioCtx->recLeft.clear();
            _audioCtx->recRight.clear();
        }
        _audioCtx->bridge.isRecordingWav.store(true, std::memory_order_relaxed);
        [_recBtn setTitle:@"■ Stop & Save WAV..."];
        [_statusLabel setStringValue:@"● Recording 44.1kHz Stereo WAV..."];
    } else {
        _audioCtx->bridge.isRecordingWav.store(false, std::memory_order_relaxed);
    }
}

- (void)panicAction:(id)sender {
    (void)sender;
    _audioCtx->isDemoPlaying.store(false, std::memory_order_relaxed);
    [_demoBtn setTitle:@"▶ Play 8-Bit Arcade Demo"];
    _audioCtx->bridge.pushUiNoteEvent(-1, 0.0f, false);
    [_statusLabel setStringValue:@"All Voices Reset (Panic)"];
}

- (void)savePatchAction:(id)sender {
    (void)sender;
    NSSavePanel* panel = [NSSavePanel savePanel];
    [panel setTitle:@"Save Pixel-Blaze 1999 Game Pak Patch"];
    [panel setNameFieldStringValue:@"CustomGamePak.pb99"];
    if ([panel runModal] == NSModalResponseOK && [panel URL]) {
        const char* path = [[[panel URL] path] UTF8String];
        FILE* f = std::fopen(path, "wb");
        if (f) {
            uint32_t magic = kPatchFileMagic;
            int32_t presetIdx = _audioCtx->bridge.currentPreset.load(std::memory_order_relaxed);
            std::fwrite(&magic, sizeof(magic), 1, f);
            std::fwrite(&presetIdx, sizeof(presetIdx), 1, f);
            for (uint32_t i = 0; i < PixelBlaze::kNumParams; ++i) {
                float v = _audioCtx->bridge.params[i].load(std::memory_order_relaxed);
                std::fwrite(&v, sizeof(float), 1, f);
            }
            for (int s = 0; s < 32; ++s) {
                uint8_t w = _audioCtx->bridge.waveRam[s].load(std::memory_order_relaxed);
                std::fwrite(&w, sizeof(uint8_t), 1, f);
            }
            for (int a = 0; a < 8; ++a) {
                int8_t st = _audioCtx->bridge.arpSteps[a].load(std::memory_order_relaxed);
                std::fwrite(&st, sizeof(int8_t), 1, f);
            }
            std::fclose(f);
            [_statusLabel setStringValue:@"Saved Game Pak Patch (.pb99)"];
        }
    }
}

- (void)loadPatchAction:(id)sender {
    (void)sender;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setTitle:@"Load Pixel-Blaze 1999 Game Pak Patch (.pb99)"];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    if ([panel runModal] == NSModalResponseOK && [panel URL]) {
        const char* path = [[[panel URL] path] UTF8String];
        FILE* f = std::fopen(path, "rb");
        if (f) {
            uint32_t magic = 0;
            if (std::fread(&magic, sizeof(magic), 1, f) == 1 && magic == kPatchFileMagic) {
                int32_t presetIdx = 0;
                std::fread(&presetIdx, sizeof(presetIdx), 1, f);
                _audioCtx->bridge.currentPreset.store(std::clamp(presetIdx, 0, PixelBlaze::kNumPresets - 1), std::memory_order_relaxed);
                for (uint32_t i = 0; i < PixelBlaze::kNumParams; ++i) {
                    float v = 0.0f;
                    if (std::fread(&v, sizeof(float), 1, f) == 1) {
                        _audioCtx->bridge.params[i].store(std::clamp(v, 0.0f, 1.0f), std::memory_order_relaxed);
                    }
                }
                for (int s = 0; s < 32; ++s) {
                    uint8_t w = 8;
                    if (std::fread(&w, sizeof(uint8_t), 1, f) == 1) {
                        _audioCtx->bridge.waveRam[s].store(w & 0x0F, std::memory_order_relaxed);
                    }
                }
                for (int a = 0; a < 8; ++a) {
                    int8_t st = 0;
                    if (std::fread(&st, sizeof(int8_t), 1, f) == 1) {
                        _audioCtx->bridge.arpSteps[a].store(st, std::memory_order_relaxed);
                    }
                }
                [_statusLabel setStringValue:@"Loaded Game Pak Patch (.pb99)"];
            }
            std::fclose(f);
        }
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    (void)notification;
    if (_uiPollTimer) {
        [_uiPollTimer invalidate];
        _uiPollTimer = nil;
    }
    if (_audioCtx) {
        if (_audioCtx->queue) {
            AudioQueueStop(_audioCtx->queue, true);
            AudioQueueDispose(_audioCtx->queue, true);
        }
        if (_audioCtx->midiInPort) MIDIPortDispose(_audioCtx->midiInPort);
        if (_audioCtx->midiClient) MIDIClientDispose(_audioCtx->midiClient);
    }
    if (_editorViewPtr) {
        PixelBlaze::destroyStandaloneEditorNsView(_editorViewPtr);
        _editorViewPtr = nullptr;
    }
}

@end

int main(int argc, const char* argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        PixelBlazeStandaloneAppDelegate* delegate = [[PixelBlazeStandaloneAppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
