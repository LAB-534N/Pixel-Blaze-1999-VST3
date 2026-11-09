#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include "PixelBlazeGUI.h"
#include "PixelBlazeParams.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <algorithm>

using namespace Steinberg;

namespace {

struct ConsoleSkinPalette {
    const char* name;
    // Outer console plastic shell
    float shellR, shellG, shellB;
    // Recessed control deck panel
    float panelR, panelG, panelB;
    // Secondary accent stripe / bezel
    float bezelR, bezelG, bezelB;
    // Primary hardware accent (buttons, labels, stripes)
    float accentR, accentG, accentB;
    // CRT / LCD Screen background
    float screenBgR, screenBgG, screenBgB;
    // CRT / LCD Phosphor / Pixel foreground
    float screenFgR, screenFgG, screenFgB;
    // Secondary screen trace color
    float screenSecR, screenSecG, screenSecB;
    // Text on shell/panel
    float textR, textG, textB;
    // Knob body color
    float knobR, knobG, knobB;
};

static const ConsoleSkinPalette kSkins[4] = {
    // 0: NES 1985 (Light Gray Plastic, Dark Charcoal Deck, Crimson Red A/B, Cyan/Green CRT)
    {
        "NES 1985",
        0.80f, 0.80f, 0.82f,   // Light NES gray shell
        0.16f, 0.17f, 0.19f,   // Dark charcoal control deck
        0.10f, 0.11f, 0.13f,   // Deep black/gray CRT bezel
        0.88f, 0.16f, 0.18f,   // Nintendo crimson red
        0.04f, 0.08f, 0.07f,   // Deep phosphor CRT dark
        0.15f, 0.96f, 0.62f,   // High-contrast arcade phosphor green/cyan
        1.00f, 0.82f, 0.20f,   // Gold secondary trace
        0.92f, 0.93f, 0.95f,   // Crisp light text on dark deck
        0.24f, 0.25f, 0.28f    // Dark gray rotary caps
    },
    // 1: FAMICOM 1983 (Cream Ivory & Deep Maroon Red, Brushed Gold Faceplate, Amber/Red CRT)
    {
        "FAMI 1983",
        0.92f, 0.88f, 0.78f,   // Vintage Famicom warm ivory shell
        0.44f, 0.09f, 0.14f,   // Deep Famicom maroon deck
        0.76f, 0.62f, 0.32f,   // Brushed metallic gold accent bezel
        0.95f, 0.76f, 0.25f,   // Bright gold highlights
        0.08f, 0.04f, 0.03f,   // Warm dark amber CRT
        1.00f, 0.68f, 0.15f,   // Glowing amber phosphor
        1.00f, 0.30f, 0.35f,   // Crimson secondary trace
        0.98f, 0.93f, 0.80f,   // Cream gold text
        0.26f, 0.06f, 0.09f    // Deep maroon knobs
    },
    // 2: GAME BOY DMG-01 1989 (Putty Gray Shell, Slate Bezel, Magenta A/B, Olive Dot-Matrix LCD)
    {
        "DMG-01 89",
        0.74f, 0.73f, 0.69f,   // Authentic Game Boy DMG putty gray
        0.24f, 0.25f, 0.30f,   // Dark slate screen surround
        0.15f, 0.16f, 0.20f,   // Deep slate bezel
        0.92f, 0.20f, 0.54f,   // High-contrast DMG magenta/berry accent
        0.54f, 0.65f, 0.14f,   // Classic DMG olive-green backlit LCD background!
        0.06f, 0.18f, 0.06f,   // Dark forest green dot-matrix LCD ink!
        0.18f, 0.34f, 0.10f,   // Mid-tone DMG pixel shade
        0.95f, 0.95f, 0.92f,   // Light text on slate panels
        0.18f, 0.19f, 0.23f    // Navy/charcoal DMG D-pad/knob color
    },
    // 3: C64 BREADBIN 1982 (Warm Beige Case, Dark Brown Keys/Deck, Blue 6581 Monitor)
    {
        "C64 1982",
        0.76f, 0.70f, 0.58f,   // Warm Commodore breadbin beige
        0.22f, 0.17f, 0.13f,   // Classic C64 dark coffee brown deck
        0.15f, 0.12f, 0.09f,   // Deep brown bezel
        0.35f, 0.68f, 1.00f,   // C64 cyan/blue accent
        0.16f, 0.14f, 0.48f,   // Iconic C64 BASIC dark blue screen
        0.52f, 0.76f, 1.00f,   // Iconic C64 BASIC light blue phosphor text/trace
        1.00f, 0.85f, 0.32f,   // C64 yellow accent
        0.95f, 0.90f, 0.82f,   // Warm beige text
        0.30f, 0.23f, 0.18f    // Brown mechanical keycap knobs
    }
};

struct KnobControlRect {
    uint32_t paramId;
    NSRect rect;
    const char* title;
};

static void formatParamDisplay(uint32_t paramId, float norm, char* buf, size_t bufLen) {
    switch (paramId) {
        case PixelBlaze::kParamChipMode: {
            int m = std::clamp(static_cast<int>(std::round(norm * 3.0f)), 0, 3);
            const char* names[4] = {"NES 2A03", "DMG-01", "SID 6581", "SN76489"};
            std::snprintf(buf, bufLen, "%s", names[m]);
            break;
        }
        case PixelBlaze::kParamPulseDuty: {
            int d = std::clamp(static_cast<int>(norm * 3.99f), 0, 3);
            const char* duties[4] = {"12.5%", "25.0%", "50.0%", "75.0%"};
            std::snprintf(buf, bufLen, "%s", duties[d]);
            break;
        }
        case PixelBlaze::kParamPitchSweep: {
            int pct = static_cast<int>(std::round((norm - 0.5f) * 200.0f));
            if ( std::abs(pct) <= 3 ) std::snprintf(buf, bufLen, "OFF");
            else std::snprintf(buf, bufLen, "%+d%%", pct);
            break;
        }
        case PixelBlaze::kParamGlideTime:
            std::snprintf(buf, bufLen, "%d ms", static_cast<int>(norm * norm * 450.0f));
            break;
        case PixelBlaze::kParamVibratoRate:
            std::snprintf(buf, bufLen, "%.1f Hz", 1.5f + norm * 12.5f);
            break;
        case PixelBlaze::kParamArpSpeed:
            std::snprintf(buf, bufLen, "%.0f Hz", 10.0f + norm * 50.0f);
            break;
        case PixelBlaze::kParamDacBits:
            std::snprintf(buf, bufLen, "%.1f-BIT", 4.0f + norm * 8.0f);
            break;
        case PixelBlaze::kParamFilterCutoff: {
            float hz = 90.0f * std::pow(190.0f, norm);
            if (hz >= 1000.0f) std::snprintf(buf, bufLen, "%.1fkHz", hz / 1000.0f);
            else std::snprintf(buf, bufLen, "%.0f Hz", hz);
            break;
        }
        case PixelBlaze::kParamEchoTime:
            std::snprintf(buf, bufLen, "%d ms", static_cast<int>(45.0f + norm * 420.0f));
            break;
        case PixelBlaze::kParamEnvAttack:
            std::snprintf(buf, bufLen, "%d ms", static_cast<int>(1.0f + norm * norm * 1400.0f));
            break;
        case PixelBlaze::kParamEnvDecay:
            std::snprintf(buf, bufLen, "%d ms", static_cast<int>(12.0f + norm * norm * 2400.0f));
            break;
        case PixelBlaze::kParamEnvRelease:
            std::snprintf(buf, bufLen, "%d ms", static_cast<int>(8.0f + norm * norm * 2200.0f));
            break;
        default:
            std::snprintf(buf, bufLen, "%d%%", static_cast<int>(std::round(norm * 100.0f)));
            break;
    }
}

} // namespace

@interface PixelBlazeEditorView_v1 : NSView {
@public
    PixelBlaze::SharedSynthBridge* _bridge;
    PixelBlaze::IEditorParamCallback* _callback;
    NSTimer* _animTimer;

    KnobControlRect _knobs[18];
    int _activeDragKnob;
    CGFloat _dragStartY;
    float _dragStartVal;

    // Interactive regions
    NSRect _prevPresetRect;
    NSRect _nextPresetRect;
    NSRect _cartSlotRect;
    NSRect _skinBtnRects[4];
    NSRect _monoBtnRect;
    NSRect _recWavBtnRect;

    // Left deck: 4 Chip buttons + Physical D-Pad
    NSRect _chipBtnRects[4];
    NSRect _dpadRect;
    bool _draggingDpad;

    // Center CRT Screen & tabs
    NSRect _crtScreenRect;
    NSRect _crtPlotRect;
    NSRect _screenTabRects[3];
    NSRect _wavePresetBtnRects[6];
    NSRect _arpPresetBtnRects[6];
    bool _draggingWaveRam;
    bool _draggingArpGrid;

    // Right deck: B / A Arcade buttons, SELECT / START, Noise & Filter Mode switches
    NSRect _btnBRect;
    NSRect _btnARect;
    NSRect _btnSelectRect;
    NSRect _btnStartRect;
    NSRect _noiseModeRects[3];
    NSRect _filterModeRects[3];
    bool _btnBPressed;
    bool _btnAPressed;

    // Bottom performance bay & 3-octave keyboard
    NSRect _pitchWheelRect;
    NSRect _modWheelRect;
    NSRect _masterKnobRect;
    bool _draggingPitchWheel;
    bool _draggingModWheel;
    bool _draggingMasterKnob;

    NSRect _keyboardRect;
    int _mouseHeldPitch;
    uint32_t _randSeed;
    uint32_t _frameCount;
}
- (instancetype)initWithFrame:(NSRect)frame
                       bridge:(PixelBlaze::SharedSynthBridge*)bridge
                     callback:(PixelBlaze::IEditorParamCallback*)callback;
- (void)stopTimer;
@end

@implementation PixelBlazeEditorView_v1

- (instancetype)initWithFrame:(NSRect)frame
                       bridge:(PixelBlaze::SharedSynthBridge*)bridge
                     callback:(PixelBlaze::IEditorParamCallback*)callback {
    self = [super initWithFrame:frame];
    if (self) {
        _bridge = bridge;
        _callback = callback;
        _activeDragKnob = -1;
        _draggingDpad = false;
        _draggingWaveRam = false;
        _draggingArpGrid = false;
        _btnBPressed = false;
        _btnAPressed = false;
        _draggingPitchWheel = false;
        _draggingModWheel = false;
        _draggingMasterKnob = false;
        _mouseHeldPitch = -1;
        _randSeed = 0x1999B1A2u;
        _frameCount = 0;

        [self setupLayout];

        _animTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                      target:self
                                                    selector:@selector(onTick:)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_animTimer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)stopTimer {
    if (_animTimer) {
        [_animTimer invalidate];
        _animTimer = nil;
    }
}

- (void)dealloc {
    [self stopTimer];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)onTick:(NSTimer*)timer {
    (void)timer;
    _frameCount++;
    [self setNeedsDisplay:YES];
}

- (void)setupLayout {
    // 1. Top Console Header & Game Pak Cartridge Slot (y = 594..670)
    for (int i = 0; i < 4; ++i) {
        _skinBtnRects[i] = NSMakeRect(22 + i * 64, 600, 60, 22);
    }

    _prevPresetRect = NSMakeRect(306, 604, 42, 54);
    _cartSlotRect   = NSMakeRect(354, 598, 320, 68);
    _nextPresetRect = NSMakeRect(680, 604, 42, 54);

    _monoBtnRect    = NSMakeRect(742, 634, 118, 26);
    _recWavBtnRect  = NSMakeRect(742, 600, 118, 28);

    // 2. Left Console Deck (x = 18..258, y = 354..584)
    for (int i = 0; i < 4; ++i) {
        int col = i % 2;
        int row = i / 2;
        _chipBtnRects[i] = NSMakeRect(28 + col * 112, 530 - row * 30, 106, 25);
    }
    _dpadRect = NSMakeRect(82, 372, 112, 112);

    // 3. Center CRT / LCD Screen (x = 270..770, y = 354..584)
    _crtScreenRect = NSMakeRect(270, 354, 500, 230);
    for (int i = 0; i < 3; ++i) {
        _screenTabRects[i] = NSMakeRect(282 + i * 160, 552, 152, 24);
    }
    _crtPlotRect = NSMakeRect(284, 392, 472, 152);
    for (int i = 0; i < 6; ++i) {
        _wavePresetBtnRects[i] = NSMakeRect(284 + i * 79, 362, 75, 22);
        _arpPresetBtnRects[i]  = NSMakeRect(284 + i * 79, 362, 75, 22);
    }

    // 4. Right Console Deck (x = 782..1022, y = 354..584)
    _btnBRect      = NSMakeRect(806, 464, 78, 78);
    _btnARect      = NSMakeRect(912, 484, 78, 78);
    _btnSelectRect = NSMakeRect(804, 424, 92, 26);
    _btnStartRect  = NSMakeRect(908, 424, 92, 26);

    for (int i = 0; i < 3; ++i) {
        _noiseModeRects[i]  = NSMakeRect(796 + i * 72, 390, 68, 22);
        _filterModeRects[i] = NSMakeRect(796 + i * 72, 362, 68, 22);
    }

    // 5. Middle 18-Knob Synth Rack (y = 148..342)
    // Module 1: 8-BIT OSCILLATORS & PITCH (6 knobs, 3x2 grid in x = 18..346)
    const uint32_t mod1Params[6] = {
        PixelBlaze::kParamPulseDuty, PixelBlaze::kParamSubWaveLevel, PixelBlaze::kParamNoiseLevel,
        PixelBlaze::kParamPitchSweep, PixelBlaze::kParamGlideTime, PixelBlaze::kParamVibratoDepth
    };
    const char* mod1Titles[6] = {
        "PULSE DUTY", "TRI / WAVE", "LFSR NOISE",
        "PITCH SWEEP", "PORTAMENTO", "60HZ VIBRATO"
    };
    for (int i = 0; i < 6; ++i) {
        int col = i % 3;
        int row = i / 3;
        CGFloat kx = 36 + col * 104;
        CGFloat ky = (row == 0) ? 240 : 158;
        _knobs[i] = {mod1Params[i], NSMakeRect(kx, ky, 76, 74), mod1Titles[i]};
    }

    // Module 2: 4-BIT ENVELOPE & TRACKER ARP (6 knobs, 3x2 grid in x = 356..684)
    const uint32_t mod2Params[6] = {
        PixelBlaze::kParamEnvAttack, PixelBlaze::kParamEnvDecay, PixelBlaze::kParamEnvSustain,
        PixelBlaze::kParamEnvRelease, PixelBlaze::kParamArpSpeed, PixelBlaze::kParamDacBits
    };
    const char* mod2Titles[6] = {
        "ENV ATTACK", "ENV DECAY", "ENV SUSTAIN",
        "ENV RELEASE", "ARP HZ CLOCK", "DAC BIT DEPTH"
    };
    for (int i = 0; i < 6; ++i) {
        int col = i % 3;
        int row = i / 3;
        CGFloat kx = 374 + col * 104;
        CGFloat ky = (row == 0) ? 240 : 158;
        _knobs[6 + i] = {mod2Params[i], NSMakeRect(kx, ky, 76, 74), mod2Titles[i]};
    }

    // Module 3: SID 6581 FILTER & TRACKER ECHO (6 knobs, 3x2 grid in x = 694..1022)
    const uint32_t mod3Params[6] = {
        PixelBlaze::kParamSampleRateCrush, PixelBlaze::kParamFilterCutoff, PixelBlaze::kParamFilterReso,
        PixelBlaze::kParamEchoTime, PixelBlaze::kParamEchoFeedback, PixelBlaze::kParamEchoMix
    };
    const char* mod3Titles[6] = {
        "ALIAS CRUSH", "SID CUTOFF", "SID RESO",
        "ECHO TIME", "ECHO REGEN", "ECHO MIX"
    };
    for (int i = 0; i < 6; ++i) {
        int col = i % 3;
        int row = i / 3;
        CGFloat kx = 712 + col * 104;
        CGFloat ky = (row == 0) ? 240 : 158;
        _knobs[12 + i] = {mod3Params[i], NSMakeRect(kx, ky, 76, 74), mod3Titles[i]};
    }

    // 6. Bottom Performance Bay & 3-Octave Chiptune Keyboard (y = 14..136)
    _pitchWheelRect = NSMakeRect(28, 22, 32, 92);
    _modWheelRect   = NSMakeRect(70, 22, 32, 92);
    _masterKnobRect = NSMakeRect(114, 34, 72, 74);
    _keyboardRect   = NSMakeRect(202, 16, 816, 114);
}

- (void)setParamNorm:(uint32_t)paramId value:(float)norm {
    norm = std::clamp(norm, 0.0f, 1.0f);
    if (_bridge) {
        _bridge->params[paramId].store(norm, std::memory_order_relaxed);
    }
    if (_callback) {
        _callback->onGuiBeginEdit(paramId);
        _callback->onGuiPerformEdit(paramId, norm);
        _callback->onGuiEndEdit(paramId);
    }
}

- (void)drawText:(NSString*)str rect:(NSRect)r font:(NSFont*)font color:(NSColor*)color align:(NSTextAlignment)align {
    NSMutableParagraphStyle* p = [[NSMutableParagraphStyle alloc] init];
    [p setAlignment:align];
    NSDictionary* attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: p
    };
    [str drawInRect:r withAttributes:attrs];
}

- (void)drawKnob:(CGContextRef)ctx knob:(const KnobControlRect&)k skin:(const ConsoleSkinPalette&)skin {
    float norm = _bridge ? _bridge->params[k.paramId].load(std::memory_order_relaxed) : 0.5f;
    CGFloat cx = NSMidX(k.rect);
    CGFloat cy = k.rect.origin.y + 36.5;
    CGFloat radius = 18.0;

    // Outer shadow ring
    CGContextSaveGState(ctx);
    CGContextSetRGBFillColor(ctx, 0.05f, 0.05f, 0.07f, 0.85f);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - radius - 2.5, cy - radius - 2.5, (radius + 2.5) * 2, (radius + 2.5) * 2));

    // Background arc track (-135 deg to +135 deg)
    CGFloat startAngle = 225.0 * M_PI / 180.0;
    CGFloat endAngle   = -45.0 * M_PI / 180.0;
    CGContextSetRGBStrokeColor(ctx, 0.08f, 0.09f, 0.11f, 1.0f);
    CGContextSetLineWidth(ctx, 3.5f);
    CGContextBeginPath(ctx);
    CGContextAddArc(ctx, cx, cy, radius + 4.0, startAngle, endAngle, 1);
    CGContextStrokePath(ctx);

    // Active value LED arc
    CGFloat valAngle = (225.0 - norm * 270.0) * M_PI / 180.0;
    CGContextSetRGBStrokeColor(ctx, skin.accentR, skin.accentG, skin.accentB, 0.95f);
    CGContextSetLineWidth(ctx, 3.5f);
    CGContextBeginPath(ctx);
    CGContextAddArc(ctx, cx, cy, radius + 4.0, startAngle, valAngle, 1);
    CGContextStrokePath(ctx);

    // Molded Console Knob Cap
    CGContextSetRGBFillColor(ctx, skin.knobR, skin.knobG, skin.knobB, 1.0f);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - radius, cy - radius, radius * 2, radius * 2));
    CGContextSetRGBStrokeColor(ctx, 0.85f, 0.85f, 0.88f, 0.25f);
    CGContextSetLineWidth(ctx, 1.5f);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - radius + 1, cy - radius + 1, (radius - 1) * 2, (radius - 1) * 2));

    // Pointer indicator line
    CGFloat px = cx + std::cos(valAngle) * (radius - 3.5);
    CGFloat py = cy + std::sin(valAngle) * (radius - 3.5);
    CGContextSetRGBStrokeColor(ctx, 1.0f, 1.0f, 1.0f, 0.95f);
    CGContextSetLineWidth(ctx, 2.3f);
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, cx + std::cos(valAngle) * 4.5, cy + std::sin(valAngle) * 4.5);
    CGContextAddLineToPoint(ctx, px, py);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);

    // Title & Value Readout
    NSFont* titleFont = [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightBold];
    NSFont* valFont   = [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightBold];
    NSColor* textCol  = [NSColor colorWithSRGBRed:skin.textR green:skin.textG blue:skin.textB alpha:0.92f];
    NSColor* valCol   = [NSColor colorWithSRGBRed:skin.screenFgR green:skin.screenFgG blue:skin.screenFgB alpha:0.98f];
    if (skin.screenBgR > 0.4f) {
        // For DMG olive skin, use crisp lime-gold readout on dark panel
        valCol = [NSColor colorWithSRGBRed:0.78f green:0.95f blue:0.35f alpha:1.0f];
    }

    [self drawText:[NSString stringWithUTF8String:k.title]
              rect:NSMakeRect(k.rect.origin.x - 8, k.rect.origin.y + 0, k.rect.size.width + 16, 12)
              font:titleFont
             color:textCol
             align:NSTextAlignmentCenter];

    char valBuf[32];
    formatParamDisplay(k.paramId, norm, valBuf, sizeof(valBuf));
    [self drawText:[NSString stringWithUTF8String:valBuf]
              rect:NSMakeRect(k.rect.origin.x - 8, k.rect.origin.y + 62, k.rect.size.width + 16, 12)
              font:valFont
             color:valCol
             align:NSTextAlignmentCenter];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) return;

    float skinNorm = _bridge ? _bridge->params[PixelBlaze::kParamConsoleSkin].load(std::memory_order_relaxed) : 0.0f;
    int skinIdx = std::clamp(static_cast<int>(std::round(skinNorm * 3.0f)), 0, 3);
    const ConsoleSkinPalette& skin = kSkins[skinIdx];

    NSRect bounds = [self bounds];

    // ========================================================================
    // 1. OUTER MOLDED CONSOLE SHELL & BEVELS
    // ========================================================================
    CGContextSetRGBFillColor(ctx, skin.shellR, skin.shellG, skin.shellB, 1.0f);
    CGContextFillRect(ctx, bounds);

    // Molded console ventilation grooves along top-left & top-right shell
    CGContextSetRGBFillColor(ctx, skin.shellR * 0.78f, skin.shellG * 0.78f, skin.shellB * 0.78f, 1.0f);
    for (int g = 0; g < 8; ++g) {
        CGContextFillRect(ctx, CGRectMake(24 + g * 8, 668, 4, 8));
        CGContextFillRect(ctx, CGRectMake(956 + g * 8, 668, 4, 8));
    }

    // ========================================================================
    // 2. TOP CONSOLE HEADER BAR & GAME PAK CARTRIDGE SLOT (y = 592..670)
    // ========================================================================
    NSRect topDeck = NSMakeRect(16, 592, 1008, 76);
    CGContextSetRGBFillColor(ctx, skin.panelR, skin.panelG, skin.panelB, 1.0f);
    CGContextFillRect(ctx, topDeck);
    CGContextSetRGBStrokeColor(ctx, skin.accentR, skin.accentG, skin.accentB, 0.85f);
    CGContextSetLineWidth(ctx, 2.0f);
    CGContextStrokeRect(ctx, topDeck);

    // Power LED + PIXEL-BLAZE 1999 Console Badge
    CGContextSetRGBFillColor(ctx, 1.0f, 0.18f, 0.18f, 1.0f);
    CGContextFillEllipseInRect(ctx, CGRectMake(28, 642, 10, 10));
    CGContextSetRGBFillColor(ctx, 1.0f, 0.55f, 0.55f, 0.9f);
    CGContextFillEllipseInRect(ctx, CGRectMake(30, 645, 4, 4));

    NSFont* logoFont = [NSFont monospacedSystemFontOfSize:17.0 weight:NSFontWeightHeavy];
    NSFont* subLogoFont = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold];
    NSColor* accentCol = [NSColor colorWithSRGBRed:skin.accentR green:skin.accentG blue:skin.accentB alpha:1.0f];
    NSColor* textCol   = [NSColor colorWithSRGBRed:skin.textR green:skin.textG blue:skin.textB alpha:1.0f];

    [self drawText:@"PIXEL-BLAZE 1999"
              rect:NSMakeRect(46, 636, 250, 22)
              font:logoFont
             color:accentCol
             align:NSTextAlignmentLeft];
    [self drawText:@"8-BIT ENTERTAINMENT SYSTEM"
              rect:NSMakeRect(46, 624, 250, 14)
              font:subLogoFont
             color:textCol
             align:NSTextAlignmentLeft];

    // 4 Console Skin Selector Buttons
    for (int i = 0; i < 4; ++i) {
        NSRect sr = _skinBtnRects[i];
        bool active = (i == skinIdx);
        CGContextSetRGBFillColor(ctx,
            active ? skin.accentR : skin.bezelR,
            active ? skin.accentG : skin.bezelG,
            active ? skin.accentB : skin.bezelB, 1.0f);
        CGContextFillRect(ctx, sr);
        CGContextSetRGBStrokeColor(ctx, 0.9f, 0.9f, 0.9f, active ? 0.9f : 0.3f);
        CGContextSetLineWidth(ctx, 1.0f);
        CGContextStrokeRect(ctx, sr);

        [self drawText:[NSString stringWithUTF8String:kSkins[i].name]
                  rect:NSMakeRect(sr.origin.x, sr.origin.y + 4, sr.size.width, 14)
                  font:[NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightBold]
                 color:[NSColor whiteColor]
                 align:NSTextAlignmentCenter];
    }

    // --- Interactive Game Pak Cartridge Slot Browser ---
    int presetIdx = _bridge ? std::clamp(_bridge->currentPreset.load(std::memory_order_relaxed), 0, PixelBlaze::kNumPresets - 1) : 0;
    const PixelBlaze::CartridgePreset& pak = PixelBlaze::kFactoryPresets[presetIdx];

    // Prev / Next Cartridge Eject Buttons
    CGContextSetRGBFillColor(ctx, skin.bezelR, skin.bezelG, skin.bezelB, 1.0f);
    CGContextFillRect(ctx, _prevPresetRect);
    CGContextFillRect(ctx, _nextPresetRect);
    CGContextSetRGBStrokeColor(ctx, skin.accentR, skin.accentG, skin.accentB, 0.7f);
    CGContextStrokeRect(ctx, _prevPresetRect);
    CGContextStrokeRect(ctx, _nextPresetRect);

    [self drawText:@"◀\nPAK" rect:NSMakeRect(_prevPresetRect.origin.x, _prevPresetRect.origin.y + 10, _prevPresetRect.size.width, 34)
              font:[NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightBold] color:textCol align:NSTextAlignmentCenter];
    [self drawText:@"▶\nPAK" rect:NSMakeRect(_nextPresetRect.origin.x, _nextPresetRect.origin.y + 10, _nextPresetRect.size.width, 34)
              font:[NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightBold] color:textCol align:NSTextAlignmentCenter];

    // Cartridge Slot Recess
    CGContextSetRGBFillColor(ctx, 0.04f, 0.04f, 0.05f, 1.0f);
    CGContextFillRect(ctx, _cartSlotRect);

    // Physical Game Pak Cartridge Body inside the slot
    float cR = ((pak.cartColorHex >> 16) & 0xFF) / 255.0f;
    float cG = ((pak.cartColorHex >> 8) & 0xFF) / 255.0f;
    float cB = (pak.cartColorHex & 0xFF) / 255.0f;

    NSRect cartBody = NSInsetRect(_cartSlotRect, 6, 4);
    CGContextSetRGBFillColor(ctx, cR * 0.85f, cG * 0.85f, cB * 0.85f, 1.0f);
    CGContextFillRect(ctx, cartBody);

    // Molded grip ribs on left & right of Game Pak
    CGContextSetRGBFillColor(ctx, cR * 0.55f, cG * 0.55f, cB * 0.55f, 1.0f);
    for (int r = 0; r < 6; ++r) {
        CGContextFillRect(ctx, CGRectMake(cartBody.origin.x + 4, cartBody.origin.y + 8 + r * 8, 18, 4));
        CGContextFillRect(ctx, CGRectMake(NSMaxX(cartBody) - 22, cartBody.origin.y + 8 + r * 8, 18, 4));
    }

    // Glossy Game Pak Center Label Sticker
    NSRect cartLabel = NSMakeRect(cartBody.origin.x + 28, cartBody.origin.y + 6, cartBody.size.width - 56, cartBody.size.height - 12);
    CGContextSetRGBFillColor(ctx, 0.10f, 0.11f, 0.15f, 1.0f);
    CGContextFillRect(ctx, cartLabel);
    CGContextSetRGBFillColor(ctx, cR, cG, cB, 1.0f);
    CGContextFillRect(ctx, CGRectMake(cartLabel.origin.x, NSMaxY(cartLabel) - 14, cartLabel.size.width, 14));

    NSString* pakHeader = [NSString stringWithFormat:@"GAME PAK [%s] // %s (%d/%d)",
                           pak.code, pak.category, presetIdx + 1, PixelBlaze::kNumPresets];
    [self drawText:pakHeader
              rect:NSMakeRect(cartLabel.origin.x + 4, NSMaxY(cartLabel) - 13, cartLabel.size.width - 8, 12)
              font:[NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightHeavy]
             color:[NSColor blackColor]
             align:NSTextAlignmentCenter];

    [self drawText:[NSString stringWithUTF8String:pak.name]
              rect:NSMakeRect(cartLabel.origin.x + 4, cartLabel.origin.y + 14, cartLabel.size.width - 8, 18)
              font:[NSFont monospacedSystemFontOfSize:13.0 weight:NSFontWeightHeavy]
             color:[NSColor whiteColor]
             align:NSTextAlignmentCenter];

    [self drawText:@"CLICK CARTRIDGE TO INSERT NEXT GAME PAK"
              rect:NSMakeRect(cartLabel.origin.x + 4, cartLabel.origin.y + 2, cartLabel.size.width - 8, 11)
              font:[NSFont monospacedSystemFontOfSize:7.5 weight:NSFontWeightMedium]
             color:[NSColor colorWithWhite:0.72 alpha:1.0]
             align:NSTextAlignmentCenter];

    // Right Header Controls: POLY/MONO Toggle, Console WAV Recorder Button, Stereo Peak Meters
    bool isMono = _bridge && (_bridge->params[PixelBlaze::kParamMonoMode].load(std::memory_order_relaxed) >= 0.5f);
    CGContextSetRGBFillColor(ctx, isMono ? skin.accentR : skin.bezelR, isMono ? skin.accentG : skin.bezelG, isMono ? skin.accentB : skin.bezelB, 1.0f);
    CGContextFillRect(ctx, _monoBtnRect);
    CGContextSetRGBStrokeColor(ctx, 1.0f, 1.0f, 1.0f, 0.4f);
    CGContextStrokeRect(ctx, _monoBtnRect);
    [self drawText:(isMono ? @"MODE: MONO LEAD" : @"MODE: 12V POLY")
              rect:NSMakeRect(_monoBtnRect.origin.x, _monoBtnRect.origin.y + 6, _monoBtnRect.size.width, 14)
              font:[NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold]
             color:[NSColor whiteColor]
             align:NSTextAlignmentCenter];

    bool isRec = _bridge && _bridge->isRecordingWav.load(std::memory_order_relaxed);
    CGContextSetRGBFillColor(ctx, isRec ? 0.92f : 0.20f, isRec ? 0.12f : 0.22f, isRec ? 0.15f : 0.26f, 1.0f);
    CGContextFillRect(ctx, _recWavBtnRect);
    CGContextSetRGBStrokeColor(ctx, 1.0f, 0.35f, 0.35f, 0.8f);
    CGContextStrokeRect(ctx, _recWavBtnRect);
    [self drawText:(isRec ? @"■ STOP & SAVE WAV" : @"● REC WAV SFX")
              rect:NSMakeRect(_recWavBtnRect.origin.x, _recWavBtnRect.origin.y + 7, _recWavBtnRect.size.width, 14)
              font:[NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightBold]
             color:[NSColor whiteColor]
             align:NSTextAlignmentCenter];

    // Stereo LED Peak Meter Bar (x = 872..1012)
    float pkL = _bridge ? std::clamp(_bridge->meterPeakL.load(std::memory_order_relaxed), 0.0f, 1.0f) : 0.0f;
    float pkR = _bridge ? std::clamp(_bridge->meterPeakR.load(std::memory_order_relaxed), 0.0f, 1.0f) : 0.0f;
    int activeVoices = _bridge ? _bridge->activeVoiceCount.load(std::memory_order_relaxed) : 0;

    [self drawText:[NSString stringWithFormat:@"VOICES: %02d/12", activeVoices]
              rect:NSMakeRect(872, 644, 140, 14)
              font:[NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold]
             color:textCol
             align:NSTextAlignmentLeft];

    for (int ch = 0; ch < 2; ++ch) {
        float lvl = (ch == 0) ? pkL : pkR;
        CGFloat my = (ch == 0) ? 624 : 604;
        [self drawText:(ch == 0 ? @"L" : @"R")
                  rect:NSMakeRect(872, my - 1, 12, 14)
                  font:[NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightBold]
                 color:textCol
                 align:NSTextAlignmentLeft];
        for (int seg = 0; seg < 12; ++seg) {
            float thresh = (seg + 1) / 12.0f;
            bool lit = (lvl >= thresh * 0.85f);
            if (seg >= 10) CGContextSetRGBFillColor(ctx, 1.0f, 0.2f, 0.2f, lit ? 1.0f : 0.2f);
            else if (seg >= 7) CGContextSetRGBFillColor(ctx, 1.0f, 0.85f, 0.15f, lit ? 1.0f : 0.2f);
            else CGContextSetRGBFillColor(ctx, 0.15f, 0.95f, 0.45f, lit ? 1.0f : 0.2f);
            CGContextFillRect(ctx, CGRectMake(886 + seg * 10, my, 8, 12));
        }
    }

    // ========================================================================
    // 3. LEFT CONSOLE CONTROLLER DECK: CHIP ENGINE + PHYSICAL D-PAD (y = 354..584)
    // ========================================================================
    NSRect leftDeck = NSMakeRect(16, 354, 244, 230);
    CGContextSetRGBFillColor(ctx, skin.panelR, skin.panelG, skin.panelB, 1.0f);
    CGContextFillRect(ctx, leftDeck);
    CGContextSetRGBStrokeColor(ctx, skin.bezelR, skin.bezelG, skin.bezelB, 1.0f);
    CGContextSetLineWidth(ctx, 2.0f);
    CGContextStrokeRect(ctx, leftDeck);

    [self drawText:@"SOUND CHIP ARCHITECTURE"
              rect:NSMakeRect(24, 560, 228, 16)
              font:[NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightHeavy]
             color:accentCol
             align:NSTextAlignmentCenter];

    float chipNorm = _bridge ? _bridge->params[PixelBlaze::kParamChipMode].load(std::memory_order_relaxed) : 0.0f;
    int chipMode = std::clamp(static_cast<int>(std::round(chipNorm * 3.0f)), 0, 3);
    const char* chipLabels[4] = {"2A03 NES", "DMG BOY", "6581 SID", "SN76489"};
    for (int i = 0; i < 4; ++i) {
        NSRect cr = _chipBtnRects[i];
        bool active = (i == chipMode);
        CGContextSetRGBFillColor(ctx,
            active ? skin.accentR : skin.bezelR,
            active ? skin.accentG : skin.bezelG,
            active ? skin.accentB : skin.bezelB, 1.0f);
        CGContextFillRect(ctx, cr);
        CGContextSetRGBStrokeColor(ctx, 1.0f, 1.0f, 1.0f, active ? 0.9f : 0.25f);
        CGContextStrokeRect(ctx, cr);
        [self drawText:[NSString stringWithUTF8String:chipLabels[i]]
                  rect:NSMakeRect(cr.origin.x, cr.origin.y + 7, cr.size.width, 14)
                  font:[NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold]
                 color:[NSColor whiteColor]
                 align:NSTextAlignmentCenter];
    }

    // Physical Cross D-Pad (X = Cutoff/Duty Mod, Y = Vibrato/Pitch Mod)
    CGFloat dcx = NSMidX(_dpadRect);
    CGFloat dcy = NSMidY(_dpadRect);
    CGFloat armW = 34.0;
    CGFloat armL = 104.0;

    // Recessed circular well under D-Pad
    CGContextSetRGBFillColor(ctx, 0.07f, 0.08f, 0.10f, 0.9f);
    CGContextFillEllipseInRect(ctx, NSInsetRect(_dpadRect, -2, -2));

    // Molded Cross Arms
    NSRect horizArm = NSMakeRect(dcx - armL * 0.5, dcy - armW * 0.5, armL, armW);
    NSRect vertArm  = NSMakeRect(dcx - armW * 0.5, dcy - armL * 0.5, armW, armL);
    CGContextSetRGBFillColor(ctx, skin.knobR, skin.knobG, skin.knobB, 1.0f);
    CGContextFillRect(ctx, horizArm);
    CGContextFillRect(ctx, vertArm);
    CGContextSetRGBStrokeColor(ctx, 0.9f, 0.9f, 0.95f, 0.3f);
    CGContextStrokeRect(ctx, horizArm);
    CGContextStrokeRect(ctx, vertArm);

    // Center pivot indent circle
    CGContextSetRGBFillColor(ctx, 0.10f, 0.11f, 0.14f, 1.0f);
    CGContextFillEllipseInRect(ctx, CGRectMake(dcx - 9, dcy - 9, 18, 18));

    // Directional Arrows & Live D-Pad X/Y Position Puck
    [self drawText:@"▲" rect:NSMakeRect(dcx - 14, dcy + 26, 28, 16) font:[NSFont systemFontOfSize:11] color:textCol align:NSTextAlignmentCenter];
    [self drawText:@"▼" rect:NSMakeRect(dcx - 14, dcy - 44, 28, 16) font:[NSFont systemFontOfSize:11] color:textCol align:NSTextAlignmentCenter];
    [self drawText:@"◀" rect:NSMakeRect(dcx - 44, dcy - 8, 18, 16) font:[NSFont systemFontOfSize:11] color:textCol align:NSTextAlignmentCenter];
    [self drawText:@"▶" rect:NSMakeRect(dcx + 26, dcy - 8, 18, 16) font:[NSFont systemFontOfSize:11] color:textCol align:NSTextAlignmentCenter];

    float dx = _bridge ? _bridge->dpadX.load(std::memory_order_relaxed) : 0.0f;
    float dy = _bridge ? _bridge->dpadY.load(std::memory_order_relaxed) : 0.0f;
    CGFloat puckX = dcx + dx * 38.0;
    CGFloat puckY = dcy + dy * 38.0;
    CGContextSetRGBFillColor(ctx, skin.accentR, skin.accentG, skin.accentB, 1.0f);
    CGContextFillEllipseInRect(ctx, CGRectMake(puckX - 5.5, puckY - 5.5, 11, 11));

    [self drawText:@"D-PAD X:CUT/PWM  Y:VIB/BEND"
              rect:NSMakeRect(22, 356, 232, 12)
              font:[NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightBold]
             color:textCol
             align:NSTextAlignmentCenter];

    // ========================================================================
    // 4. CENTER CRT / DOT-MATRIX LCD MONITOR (x = 270..770, y = 354..584)
    // ========================================================================
    CGContextSetRGBFillColor(ctx, skin.bezelR, skin.bezelG, skin.bezelB, 1.0f);
    CGContextFillRect(ctx, _crtScreenRect);
    CGContextSetRGBStrokeColor(ctx, skin.accentR, skin.accentG, skin.accentB, 0.85f);
    CGContextSetLineWidth(ctx, 2.0f);
    CGContextStrokeRect(ctx, _crtScreenRect);

    int screenMode = _bridge ? _bridge->screenMode.load(std::memory_order_relaxed) : 0;
    const char* tabTitles[3] = {"1: CRT SCOPE & REGS", "2: 4-BIT WAVE RAM", "3: TRACKER ARP (8x)"};
    for (int t = 0; t < 3; ++t) {
        NSRect tr = _screenTabRects[t];
        bool active = (t == screenMode);
        CGContextSetRGBFillColor(ctx,
            active ? skin.accentR : (skin.panelR * 0.8f),
            active ? skin.accentG : (skin.panelG * 0.8f),
            active ? skin.accentB : (skin.panelB * 0.8f), 1.0f);
        CGContextFillRect(ctx, tr);
        [self drawText:[NSString stringWithUTF8String:tabTitles[t]]
                  rect:NSMakeRect(tr.origin.x, tr.origin.y + 5, tr.size.width, 14)
                  font:[NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightHeavy]
                 color:[NSColor whiteColor]
                 align:NSTextAlignmentCenter];
    }

    // Inner CRT / LCD Screen Glass
    CGContextSetRGBFillColor(ctx, skin.screenBgR, skin.screenBgG, skin.screenBgB, 1.0f);
    CGContextFillRect(ctx, _crtPlotRect);

    // Subtle horizontal CRT scanlines
    CGContextSetRGBStrokeColor(ctx, 0.0f, 0.0f, 0.0f, (skinIdx == 2) ? 0.12f : 0.28f);
    CGContextSetLineWidth(ctx, 1.0f);
    for (CGFloat sy = _crtPlotRect.origin.y; sy < NSMaxY(_crtPlotRect); sy += 3.0) {
        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, _crtPlotRect.origin.x, sy);
        CGContextAddLineToPoint(ctx, NSMaxX(_crtPlotRect), sy);
        CGContextStrokePath(ctx);
    }

    NSColor* crtFgCol = [NSColor colorWithSRGBRed:skin.screenFgR green:skin.screenFgG blue:skin.screenFgB alpha:1.0f];
    NSColor* crtSecCol = [NSColor colorWithSRGBRed:skin.screenSecR green:skin.screenSecG blue:skin.screenSecB alpha:1.0f];

    if (screenMode == 0) {
        // --------------------------------------------------------------------
        // SCREEN MODE 0: LIVE 8-BIT OSCILLOSCOPE + HARDWARE REGISTER HUD
        // --------------------------------------------------------------------
        // Subtle graticule grid
        CGContextSetRGBStrokeColor(ctx, skin.screenFgR, skin.screenFgG, skin.screenFgB, 0.18f);
        for (int gx = 1; gx < 8; ++gx) {
            CGFloat x = _crtPlotRect.origin.x + (_crtPlotRect.size.width * gx) / 8.0;
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, x, _crtPlotRect.origin.y);
            CGContextAddLineToPoint(ctx, x, NSMaxY(_crtPlotRect));
            CGContextStrokePath(ctx);
        }

        // Draw Stair-Stepped 8-Bit Waveform Trace
        CGContextSetRGBStrokeColor(ctx, skin.screenFgR, skin.screenFgG, skin.screenFgB, 0.96f);
        CGContextSetLineWidth(ctx, 2.2f);
        CGContextBeginPath(ctx);
        uint32_t wp = _bridge ? _bridge->scopeWritePos.load(std::memory_order_relaxed) : 0;
        int numPts = 128;
        CGFloat midY = NSMidY(_crtPlotRect) - 8.0;
        CGFloat ampH = _crtPlotRect.size.height * 0.36;
        for (int i = 0; i < numPts; ++i) {
            uint32_t idx = (wp - numPts + i) & (PixelBlaze::SharedSynthBridge::kScopeSize - 1);
            float sample = _bridge ? _bridge->scopeBuffer[idx].load(std::memory_order_relaxed) : 0.0f;
            sample = std::clamp(sample, -1.0f, 1.0f);
            CGFloat x = _crtPlotRect.origin.x + 8 + ((_crtPlotRect.size.width - 16) * i) / (numPts - 1);
            CGFloat y = midY + sample * ampH;
            if (i == 0) CGContextMoveToPoint(ctx, x, y);
            else {
                // Authentic stair-stepped digital oscilloscope look
                CGFloat prevX = _crtPlotRect.origin.x + 8 + ((_crtPlotRect.size.width - 16) * (i - 1)) / (numPts - 1);
                CGContextAddLineToPoint(ctx, x, y);
                (void)prevX;
            }
        }
        CGContextStrokePath(ctx);

        // Hardware Chip Register Readout Overlay at top of CRT
        uint8_t reg4000 = static_cast<uint8_t>((static_cast<int>(_bridge->params[PixelBlaze::kParamPulseDuty].load() * 3.99f) << 6) | 0x3F);
        uint8_t regD404 = static_cast<uint8_t>(0x21 | ( static_cast<int>(_bridge->params[PixelBlaze::kParamFilterCutoff].load() * 15.0f) << 4 ));
        int arpStep = _bridge ? _bridge->activeArpStep.load(std::memory_order_relaxed) : 0;
        NSString* regLine = [NSString stringWithFormat:@"$4000:%02X  $D404:%02X  $FF30:WAVE[32]  ARP.STEP:%d/8  CLK:60Hz NTSC",
                             reg4000, regD404, arpStep + 1];
        [self drawText:regLine
                  rect:NSMakeRect(_crtPlotRect.origin.x + 8, NSMaxY(_crtPlotRect) - 18, _crtPlotRect.size.width - 16, 14)
                  font:[NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightBold]
                 color:crtSecCol
                 align:NSTextAlignmentLeft];

        // Bottom bar under CRT: 6 Quick Wave Presets (can also click to jump into Wave Editor!)
        const char* waveQuickNames[6] = {"PULSE WAVE", "STAIR SAW", "NES TRI", "FM BELL", "VOCAL CHIP", "RND GLITCH"};
        for (int i = 0; i < 6; ++i) {
            NSRect wr = _wavePresetBtnRects[i];
            CGContextSetRGBFillColor(ctx, skin.panelR, skin.panelG, skin.panelB, 1.0f);
            CGContextFillRect(ctx, wr);
            CGContextSetRGBStrokeColor(ctx, skin.screenFgR, skin.screenFgG, skin.screenFgB, 0.5f);
            CGContextStrokeRect(ctx, wr);
            [self drawText:[NSString stringWithUTF8String:waveQuickNames[i]]
                      rect:NSMakeRect(wr.origin.x, wr.origin.y + 4, wr.size.width, 13)
                      font:[NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightBold]
                     color:textCol
                     align:NSTextAlignmentCenter];
        }

    } else if (screenMode == 1) {
        // --------------------------------------------------------------------
        // SCREEN MODE 1: INTERACTIVE 32-STEP x 16-LEVEL (4-BIT) WAVE RAM EDITOR
        // --------------------------------------------------------------------
        CGFloat padX = 10.0, padY = 18.0;
        CGFloat gridW = _crtPlotRect.size.width - padX * 2;
        CGFloat gridH = _crtPlotRect.size.height - padY - 8.0;
        CGFloat cellW = gridW / 32.0;
        CGFloat cellH = gridH / 16.0;

        for (int s = 0; s < 32; ++s) {
            uint8_t v4 = _bridge ? (_bridge->waveRam[s].load(std::memory_order_relaxed) & 0x0F) : 8;
            CGFloat x = _crtPlotRect.origin.x + padX + s * cellW;
            CGFloat barH = (v4 + 1) * cellH;
            CGFloat y = _crtPlotRect.origin.y + 6.0;

            // Column bar fill
            CGContextSetRGBFillColor(ctx, skin.screenFgR, skin.screenFgG, skin.screenFgB, 0.35f);
            CGContextFillRect(ctx, CGRectMake(x + 1, y, cellW - 2, barH));

            // Bright 4-bit pixel block at step level
            CGContextSetRGBFillColor(ctx, skin.screenFgR, skin.screenFgG, skin.screenFgB, 0.98f);
            CGContextFillRect(ctx, CGRectMake(x + 1, y + v4 * cellH, cellW - 2, cellH - 1));

            // Hex digit (0..F) at top of each column
            char hexStr[4];
            std::snprintf(hexStr, sizeof(hexStr), "%X", v4);
            [self drawText:[NSString stringWithUTF8String:hexStr]
                      rect:NSMakeRect(x, NSMaxY(_crtPlotRect) - 14, cellW, 12)
                      font:[NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightBold]
                     color:crtSecCol
                     align:NSTextAlignmentCenter];
        }

        const char* waveQuickNames[6] = {"PULSE WAVE", "STAIR SAW", "NES TRI", "FM BELL", "VOCAL CHIP", "RND GLITCH"};
        for (int i = 0; i < 6; ++i) {
            NSRect wr = _wavePresetBtnRects[i];
            CGContextSetRGBFillColor(ctx, skin.panelR, skin.panelG, skin.panelB, 1.0f);
            CGContextFillRect(ctx, wr);
            CGContextSetRGBStrokeColor(ctx, skin.accentR, skin.accentG, skin.accentB, 0.7f);
            CGContextStrokeRect(ctx, wr);
            [self drawText:[NSString stringWithUTF8String:waveQuickNames[i]]
                      rect:NSMakeRect(wr.origin.x, wr.origin.y + 4, wr.size.width, 13)
                      font:[NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightBold]
                     color:[NSColor whiteColor]
                     align:NSTextAlignmentCenter];
        }

    } else {
        // --------------------------------------------------------------------
        // SCREEN MODE 2: INTERACTIVE 8-STEP 50/60HZ TRACKER ARPEGGIATOR GRID
        // --------------------------------------------------------------------
        CGFloat padX = 16.0;
        CGFloat stepW = (_crtPlotRect.size.width - padX * 2) / 8.0;
        CGFloat zeroY = _crtPlotRect.origin.y + _crtPlotRect.size.height * 0.42;
        int activeStep = _bridge ? (_bridge->activeArpStep.load(std::memory_order_relaxed) & 7) : 0;

        for (int a = 0; a < 8; ++a) {
            int8_t semi = _bridge ? _bridge->arpSteps[a].load(std::memory_order_relaxed) : 0;
            CGFloat sx = _crtPlotRect.origin.x + padX + a * stepW;

            if (a == activeStep) {
                CGContextSetRGBFillColor(ctx, skin.screenSecR, skin.screenSecG, skin.screenSecB, 0.18f);
                CGContextFillRect(ctx, CGRectMake(sx + 2, _crtPlotRect.origin.y + 4, stepW - 4, _crtPlotRect.size.height - 8));
            }

            CGFloat normSemi = static_cast<CGFloat>(semi) / 24.0; // -0.5 .. +1.0
            CGFloat barH = normSemi * (_crtPlotRect.size.height * 0.48);
            CGContextSetRGBFillColor(ctx, skin.screenFgR, skin.screenFgG, skin.screenFgB, (a == activeStep) ? 1.0f : 0.75f);
            if (barH >= 0) {
                CGContextFillRect(ctx, CGRectMake(sx + 6, zeroY, stepW - 12, std::max<CGFloat>(4.0, barH)));
            } else {
                CGContextFillRect(ctx, CGRectMake(sx + 6, zeroY + barH, stepW - 12, -barH));
            }

            NSString* stLabel = [NSString stringWithFormat:@"%02d: %+d ST", a + 1, semi];
            [self drawText:stLabel
                      rect:NSMakeRect(sx, NSMaxY(_crtPlotRect) - 18, stepW, 14)
                      font:[NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightBold]
                     color:(a == activeStep ? crtSecCol : crtFgCol)
                     align:NSTextAlignmentCenter];
        }

        // 6 Arp Mode Buttons along bottom of screen
        float arpPatNorm = _bridge ? _bridge->params[PixelBlaze::kParamArpPattern].load(std::memory_order_relaxed) : 0.0f;
        int arpPatIdx = std::clamp(static_cast<int>(std::round(arpPatNorm * 5.0f)), 0, 5);
        const char* arpModeNames[6] = {"MAJ CHORD", "MIN CHORD", "OCTAVE 2X", "MEGA 3-OCT", "1-UP COIN", "CUSTOM 8X"};
        for (int i = 0; i < 6; ++i) {
            NSRect ar = _arpPresetBtnRects[i];
            bool active = (i == arpPatIdx);
            CGContextSetRGBFillColor(ctx, active ? skin.accentR : skin.panelR, active ? skin.accentG : skin.panelG, active ? skin.accentB : skin.panelB, 1.0f);
            CGContextFillRect(ctx, ar);
            CGContextSetRGBStrokeColor(ctx, 1.0f, 1.0f, 1.0f, 0.5f);
            CGContextStrokeRect(ctx, ar);
            [self drawText:[NSString stringWithUTF8String:arpModeNames[i]]
                      rect:NSMakeRect(ar.origin.x, ar.origin.y + 4, ar.size.width, 13)
                      font:[NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightBold]
                     color:[NSColor whiteColor]
                     align:NSTextAlignmentCenter];
        }
    }

    // ========================================================================
    // 5. RIGHT CONSOLE ARCADE DECK: B / A BUTTONS + SELECT / START (y = 354..584)
    // ========================================================================
    NSRect rightDeck = NSMakeRect(780, 354, 244, 230);
    CGContextSetRGBFillColor(ctx, skin.panelR, skin.panelG, skin.panelB, 1.0f);
    CGContextFillRect(ctx, rightDeck);
    CGContextSetRGBStrokeColor(ctx, skin.bezelR, skin.bezelG, skin.bezelB, 1.0f);
    CGContextSetLineWidth(ctx, 2.0f);
    CGContextStrokeRect(ctx, rightDeck);

    [self drawText:@"ARCADE ACTION & MODES"
              rect:NSMakeRect(788, 564, 228, 16)
              font:[NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightHeavy]
             color:accentCol
             align:NSTextAlignmentCenter];

    // Molded square/rounded bezels around B & A buttons (classic NES controller look!)
    CGContextSetRGBFillColor(ctx, skin.shellR * 0.88f, skin.shellG * 0.88f, skin.shellB * 0.88f, 1.0f);
    CGContextFillRect(ctx, NSInsetRect(_btnBRect, -4, -4));
    CGContextFillRect(ctx, NSInsetRect(_btnARect, -4, -4));

    // Crimson/Magenta Circular B & A Arcade Buttons
    CGContextSetRGBFillColor(ctx,
        _btnBPressed ? (skin.accentR * 0.7f) : skin.accentR,
        _btnBPressed ? (skin.accentG * 0.7f) : skin.accentG,
        _btnBPressed ? (skin.accentB * 0.7f) : skin.accentB, 1.0f);
    CGContextFillEllipseInRect(ctx, NSInsetRect(_btnBRect, 4, 4));

    CGContextSetRGBFillColor(ctx,
        _btnAPressed ? (skin.accentR * 0.7f) : skin.accentR,
        _btnAPressed ? (skin.accentG * 0.7f) : skin.accentG,
        _btnAPressed ? (skin.accentB * 0.7f) : skin.accentB, 1.0f);
    CGContextFillEllipseInRect(ctx, NSInsetRect(_btnARect, 4, 4));

    [self drawText:@"B\nGLITCH"
              rect:NSMakeRect(_btnBRect.origin.x, _btnBRect.origin.y + 22, _btnBRect.size.width, 36)
              font:[NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightHeavy]
             color:[NSColor whiteColor]
             align:NSTextAlignmentCenter];

    [self drawText:@"A\nFIRE!"
              rect:NSMakeRect(_btnARect.origin.x, _btnARect.origin.y + 22, _btnARect.size.width, 36)
              font:[NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightHeavy]
             color:[NSColor whiteColor]
             align:NSTextAlignmentCenter];

    // SELECT (Skin Cycle) & START (60Hz Arp Enable) Pill Buttons
    bool arpOn = _bridge && (_bridge->params[PixelBlaze::kParamArpEnable].load(std::memory_order_relaxed) >= 0.5f);
    CGContextSetRGBFillColor(ctx, skin.knobR, skin.knobG, skin.knobB, 1.0f);
    CGContextFillRect(ctx, _btnSelectRect);
    CGContextSetRGBFillColor(ctx, arpOn ? skin.accentR : skin.knobR, arpOn ? skin.accentG : skin.knobG, arpOn ? skin.accentB : skin.knobB, 1.0f);
    CGContextFillRect(ctx, _btnStartRect);
    CGContextSetRGBStrokeColor(ctx, 1.0f, 1.0f, 1.0f, 0.5f);
    CGContextStrokeRect(ctx, _btnSelectRect);
    CGContextStrokeRect(ctx, _btnStartRect);

    [self drawText:@"SELECT SKIN"
              rect:NSMakeRect(_btnSelectRect.origin.x, _btnSelectRect.origin.y + 6, _btnSelectRect.size.width, 14)
              font:[NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightHeavy]
             color:[NSColor whiteColor]
             align:NSTextAlignmentCenter];

    [self drawText:(arpOn ? @"START ARP: ON" : @"START ARP: OFF")
              rect:NSMakeRect(_btnStartRect.origin.x, _btnStartRect.origin.y + 6, _btnStartRect.size.width, 14)
              font:[NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightHeavy]
             color:[NSColor whiteColor]
             align:NSTextAlignmentCenter];

    // Noise Mode & Filter Mode 3-way switches
    int nsMode = _bridge ? std::clamp(static_cast<int>(std::round(_bridge->params[PixelBlaze::kParamNoiseMode].load() * 2.0f)), 0, 2) : 0;
    int fltMode = _bridge ? std::clamp(static_cast<int>(std::round(_bridge->params[PixelBlaze::kParamFilterType].load() * 2.0f)), 0, 2) : 0;
    const char* nsLabels[3]  = {"NS:WHITE", "NS:METAL", "NS:DRUM"};
    const char* fltLabels[3] = {"FLT:LP", "FLT:BP", "FLT:HP"};

    for (int i = 0; i < 3; ++i) {
        bool nsAct = (i == nsMode);
        CGContextSetRGBFillColor(ctx, nsAct ? skin.accentR : skin.bezelR, nsAct ? skin.accentG : skin.bezelG, nsAct ? skin.accentB : skin.bezelB, 1.0f);
        CGContextFillRect(ctx, _noiseModeRects[i]);
        [self drawText:[NSString stringWithUTF8String:nsLabels[i]]
                  rect:NSMakeRect(_noiseModeRects[i].origin.x, _noiseModeRects[i].origin.y + 4, _noiseModeRects[i].size.width, 13)
                  font:[NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightBold]
                 color:[NSColor whiteColor]
                 align:NSTextAlignmentCenter];

        bool fltAct = (i == fltMode);
        CGContextSetRGBFillColor(ctx, fltAct ? skin.accentR : skin.bezelR, fltAct ? skin.accentG : skin.bezelG, fltAct ? skin.accentB : skin.bezelB, 1.0f);
        CGContextFillRect(ctx, _filterModeRects[i]);
        [self drawText:[NSString stringWithUTF8String:fltLabels[i]]
                  rect:NSMakeRect(_filterModeRects[i].origin.x, _filterModeRects[i].origin.y + 4, _filterModeRects[i].size.width, 13)
                  font:[NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightBold]
                 color:[NSColor whiteColor]
                 align:NSTextAlignmentCenter];
    }

    // ========================================================================
    // 6. MIDDLE 18-KNOB HARDWARE SYNTHESIS RACK (y = 148..342)
    // ========================================================================
    const NSRect modBoxes[3] = {
        NSMakeRect(16, 148, 330, 194),
        NSMakeRect(355, 148, 330, 194),
        NSMakeRect(694, 148, 330, 194)
    };
    const char* modHeaders[3] = {
        "I. 8-BIT OSCILLATORS & SWEEP",
        "II. 4-BIT ENVELOPE & 60HZ ARP",
        "III. SID 6581 FILTER & ECHO"
    };

    for (int m = 0; m < 3; ++m) {
        CGContextSetRGBFillColor(ctx, skin.panelR, skin.panelG, skin.panelB, 1.0f);
        CGContextFillRect(ctx, modBoxes[m]);
        CGContextSetRGBStrokeColor(ctx, skin.accentR, skin.accentG, skin.accentB, 0.65f);
        CGContextSetLineWidth(ctx, 1.5f);
        CGContextStrokeRect(ctx, modBoxes[m]);

        // Module header stripe
        NSRect hdr = NSMakeRect(modBoxes[m].origin.x, NSMaxY(modBoxes[m]) - 22, modBoxes[m].size.width, 22);
        CGContextSetRGBFillColor(ctx, skin.bezelR, skin.bezelG, skin.bezelB, 1.0f);
        CGContextFillRect(ctx, hdr);
        [self drawText:[NSString stringWithUTF8String:modHeaders[m]]
                  rect:NSMakeRect(hdr.origin.x + 8, hdr.origin.y + 4, hdr.size.width - 16, 14)
                  font:[NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightHeavy]
                 color:accentCol
                 align:NSTextAlignmentCenter];
    }

    for (int i = 0; i < 18; ++i) {
        [self drawKnob:ctx knob:_knobs[i] skin:skin];
    }

    // ========================================================================
    // 7. BOTTOM PERFORMANCE DECK & 3-OCTAVE 8-BIT KEYBOARD (y = 12..138)
    // ========================================================================
    NSRect botDeck = NSMakeRect(16, 10, 1008, 128);
    CGContextSetRGBFillColor(ctx, skin.panelR, skin.panelG, skin.panelB, 1.0f);
    CGContextFillRect(ctx, botDeck);
    CGContextSetRGBStrokeColor(ctx, skin.bezelR, skin.bezelG, skin.bezelB, 1.0f);
    CGContextStrokeRect(ctx, botDeck);

    // Pitch Bend & Mod Wheel Vertical Sliders
    float pbNorm  = _bridge ? _bridge->params[PixelBlaze::kParamPitchBend].load(std::memory_order_relaxed) : 0.5f;
    float modNorm = _bridge ? _bridge->params[PixelBlaze::kParamModWheel].load(std::memory_order_relaxed) : 0.0f;

    const NSRect wheelRects[2] = {_pitchWheelRect, _modWheelRect};
    const float wheelVals[2]   = {pbNorm, modNorm};
    const char* wheelNames[2]  = {"BEND", "MOD"};

    for (int w = 0; w < 2; ++w) {
        NSRect wr = wheelRects[w];
        CGContextSetRGBFillColor(ctx, 0.06f, 0.07f, 0.09f, 1.0f);
        CGContextFillRect(ctx, wr);
        CGContextSetRGBStrokeColor(ctx, 0.7f, 0.7f, 0.75f, 0.4f);
        CGContextStrokeRect(ctx, wr);

        CGFloat thumbY = wr.origin.y + 6 + wheelVals[w] * (wr.size.height - 20);
        CGContextSetRGBFillColor(ctx, skin.accentR, skin.accentG, skin.accentB, 1.0f);
        CGContextFillRect(ctx, CGRectMake(wr.origin.x + 2, thumbY, wr.size.width - 4, 8));

        [self drawText:[NSString stringWithUTF8String:wheelNames[w]]
                  rect:NSMakeRect(wr.origin.x - 4, wr.origin.y + wr.size.height + 2, wr.size.width + 8, 12)
                  font:[NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightBold]
                 color:textCol
                 align:NSTextAlignmentCenter];
    }

    // Master Volume Knob
    KnobControlRect masterK = {PixelBlaze::kParamMasterVolume, _masterKnobRect, "MASTER VOL"};
    [self drawKnob:ctx knob:masterK skin:skin];

    // 3-Octave (36 keys: C3=48 to B5=83, 21 White Keys) Retro Console Keyboard
    static const int kWhiteOffsets[7] = {0, 2, 4, 5, 7, 9, 11};
    static const char* kQwertyWhite[21] = {
        "Z","X","C","V","B","N","M",
        "Q","W","E","R","T","Y","U",
        "I","O","P","[","]","\\","/"
    };
    CGFloat whiteW = _keyboardRect.size.width / 21.0;
    CGFloat whiteH = _keyboardRect.size.height;

    for (int wk = 0; wk < 21; ++wk) {
        int oct = wk / 7;
        int deg = wk % 7;
        int midiPitch = 48 + oct * 12 + kWhiteOffsets[deg];
        bool isDown = (_bridge && _bridge->isKeyActive(midiPitch)) || (_mouseHeldPitch == midiPitch);

        NSRect kr = NSMakeRect(_keyboardRect.origin.x + wk * whiteW, _keyboardRect.origin.y, whiteW - 1.5, whiteH);
        if (isDown) {
            CGContextSetRGBFillColor(ctx, skin.accentR, skin.accentG, skin.accentB, 1.0f);
        } else {
            CGContextSetRGBFillColor(ctx, 0.93f, 0.93f, 0.90f, 1.0f);
        }
        CGContextFillRect(ctx, kr);

        // Pixel key bottom bevel
        CGContextSetRGBFillColor(ctx, 0.65f, 0.65f, 0.62f, 1.0f);
        CGContextFillRect(ctx, CGRectMake(kr.origin.x, kr.origin.y, kr.size.width, 6));

        [self drawText:[NSString stringWithUTF8String:kQwertyWhite[wk]]
                  rect:NSMakeRect(kr.origin.x, kr.origin.y + 8, kr.size.width, 12)
                  font:[NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightBold]
                 color:(isDown ? [NSColor whiteColor] : [NSColor colorWithWhite:0.25 alpha:1.0])
                 align:NSTextAlignmentCenter];
    }

    // Black Keys
    static const int kBlackAfterWhite[5] = {0, 1, 3, 4, 5};
    static const int kBlackSemi[5]       = {1, 3, 6, 8, 10};
    CGFloat blackW = whiteW * 0.64;
    CGFloat blackH = whiteH * 0.60;

    for (int oct = 0; oct < 3; ++oct) {
        for (int b = 0; b < 5; ++b) {
            int wkIdx = oct * 7 + kBlackAfterWhite[b];
            int midiPitch = 48 + oct * 12 + kBlackSemi[b];
            bool isDown = (_bridge && _bridge->isKeyActive(midiPitch)) || (_mouseHeldPitch == midiPitch);

            CGFloat bx = _keyboardRect.origin.x + (wkIdx + 1) * whiteW - blackW * 0.5;
            CGFloat by = _keyboardRect.origin.y + whiteH - blackH;
            NSRect br = NSMakeRect(bx, by, blackW, blackH);

            if (isDown) {
                CGContextSetRGBFillColor(ctx, skin.screenFgR, skin.screenFgG, skin.screenFgB, 1.0f);
            } else {
                CGContextSetRGBFillColor(ctx, 0.12f, 0.13f, 0.16f, 1.0f);
            }
            CGContextFillRect(ctx, br);
            CGContextSetRGBStrokeColor(ctx, 0.0f, 0.0f, 0.0f, 0.9f);
            CGContextStrokeRect(ctx, br);
        }
    }
}

- (int)pitchAtKeyboardPoint:(NSPoint)pt {
    if (!NSPointInRect(pt, _keyboardRect)) return -1;
    CGFloat whiteW = _keyboardRect.size.width / 21.0;
    CGFloat whiteH = _keyboardRect.size.height;
    CGFloat blackW = whiteW * 0.64;
    CGFloat blackH = whiteH * 0.60;

    static const int kBlackAfterWhite[5] = {0, 1, 3, 4, 5};
    static const int kBlackSemi[5]       = {1, 3, 6, 8, 10};
    for (int oct = 0; oct < 3; ++oct) {
        for (int b = 0; b < 5; ++b) {
            int wkIdx = oct * 7 + kBlackAfterWhite[b];
            CGFloat bx = _keyboardRect.origin.x + (wkIdx + 1) * whiteW - blackW * 0.5;
            CGFloat by = _keyboardRect.origin.y + whiteH - blackH;
            if (NSPointInRect(pt, NSMakeRect(bx, by, blackW, blackH))) {
                return 48 + oct * 12 + kBlackSemi[b];
            }
        }
    }

    static const int kWhiteOffsets[7] = {0, 2, 4, 5, 7, 9, 11};
    int wk = std::clamp(static_cast<int>((pt.x - _keyboardRect.origin.x) / whiteW), 0, 20);
    return 48 + (wk / 7) * 12 + kWhiteOffsets[wk % 7];
}

- (void)applyWaveShapePreset:(int)shapeIdx {
    if (!_bridge) return;
    for (int s = 0; s < 32; ++s) {
        uint8_t val = 8;
        if (shapeIdx == 0) { // Pulse 25%
            val = (s < 8) ? 15 : 0;
        } else if (shapeIdx == 1) { // Stair Saw
            val = static_cast<uint8_t>(15 - (s / 2));
        } else if (shapeIdx == 2) { // NES Triangle
            val = PixelBlaze::kNesTriangleTable[s];
        } else if (shapeIdx == 3) { // FM Bell Overtone
            double t = static_cast<double>(s) / 32.0;
            double v = std::sin(t * 6.2831853 + 1.8 * std::sin(t * 6.2831853 * 3.0));
            val = static_cast<uint8_t>(std::clamp(static_cast<int>((v * 0.5 + 0.5) * 15.0), 0, 15));
        } else if (shapeIdx == 4) { // Vocal Formant
            double t = static_cast<double>(s) / 32.0;
            double v = std::sin(t * 6.2831853) * 0.5 + std::sin(t * 6.2831853 * 4.0) * 0.5 * (1.0 - t);
            val = static_cast<uint8_t>(std::clamp(static_cast<int>((v * 0.5 + 0.5) * 15.0), 0, 15));
        } else { // Random Glitch Wave
            _randSeed = _randSeed * 1664525u + 1013904223u;
            val = static_cast<uint8_t>((_randSeed >> 12) & 0x0F);
        }
        _bridge->waveRam[s].store(val, std::memory_order_relaxed);
    }
    _bridge->screenMode.store(1, std::memory_order_relaxed);
}

- (void)handleCrtDrag:(NSPoint)pt {
    if (!_bridge) return;
    int mode = _bridge->screenMode.load(std::memory_order_relaxed);
    if (mode == 1 && _draggingWaveRam) {
        CGFloat padX = 10.0, padY = 18.0;
        CGFloat gridW = _crtPlotRect.size.width - padX * 2;
        CGFloat gridH = _crtPlotRect.size.height - padY - 8.0;
        int col = std::clamp(static_cast<int>((pt.x - (_crtPlotRect.origin.x + padX)) / (gridW / 32.0)), 0, 31);
        int lvl = std::clamp(static_cast<int>((pt.y - (_crtPlotRect.origin.y + 6.0)) / (gridH / 16.0)), 0, 15);
        _bridge->waveRam[col].store(static_cast<uint8_t>(lvl), std::memory_order_relaxed);
        [self setNeedsDisplay:YES];
    } else if (mode == 2 && _draggingArpGrid) {
        CGFloat padX = 16.0;
        CGFloat stepW = (_crtPlotRect.size.width - padX * 2) / 8.0;
        int step = std::clamp(static_cast<int>((pt.x - (_crtPlotRect.origin.x + padX)) / stepW), 0, 7);
        CGFloat normY = (pt.y - _crtPlotRect.origin.y) / _crtPlotRect.size.height;
        int semi = std::clamp(static_cast<int>(std::round((normY - 0.42) * 44.0)), -12, 24);
        _bridge->arpSteps[step].store(static_cast<int8_t>(semi), std::memory_order_relaxed);
        [self setParamNorm:PixelBlaze::kParamArpPattern value:1.0f]; // Switch to Custom 8x mode
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDown:(NSEvent*)event {
    [[self window] makeFirstResponder:self];
    NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];
    if (!_bridge) return;

    // 1. Skin Selector Buttons
    for (int i = 0; i < 4; ++i) {
        if (NSPointInRect(pt, _skinBtnRects[i])) {
            [self setParamNorm:PixelBlaze::kParamConsoleSkin value:(i / 3.0f)];
            [self setNeedsDisplay:YES];
            return;
        }
    }

    // 2. Cartridge Preset Slot Browser
    int curPreset = _bridge->currentPreset.load(std::memory_order_relaxed);
    if (NSPointInRect(pt, _prevPresetRect)) {
        int nextP = (curPreset - 1 + PixelBlaze::kNumPresets) % PixelBlaze::kNumPresets;
        _bridge->applyPreset(nextP);
        if (_callback) _callback->onGuiPresetSelected(nextP);
        [self setNeedsDisplay:YES];
        return;
    }
    if (NSPointInRect(pt, _nextPresetRect) || NSPointInRect(pt, _cartSlotRect)) {
        int nextP = (curPreset + 1) % PixelBlaze::kNumPresets;
        _bridge->applyPreset(nextP);
        if (_callback) _callback->onGuiPresetSelected(nextP);
        [self setNeedsDisplay:YES];
        return;
    }

    // 3. Mono/Poly & Console WAV Recorder Buttons
    if (NSPointInRect(pt, _monoBtnRect)) {
        bool isMono = _bridge->params[PixelBlaze::kParamMonoMode].load(std::memory_order_relaxed) >= 0.5f;
        [self setParamNorm:PixelBlaze::kParamMonoMode value:(isMono ? 0.0f : 1.0f)];
        [self setNeedsDisplay:YES];
        return;
    }
    if (NSPointInRect(pt, _recWavBtnRect)) {
        bool isRec = _bridge->isRecordingWav.load(std::memory_order_relaxed);
        _bridge->isRecordingWav.store(!isRec, std::memory_order_relaxed);
        [self setNeedsDisplay:YES];
        return;
    }

    // 4. Sound Chip Architecture Buttons & D-Pad
    for (int i = 0; i < 4; ++i) {
        if (NSPointInRect(pt, _chipBtnRects[i])) {
            [self setParamNorm:PixelBlaze::kParamChipMode value:(i / 3.0f)];
            [self setNeedsDisplay:YES];
            return;
        }
    }
    if (NSPointInRect(pt, _dpadRect)) {
        if ([event clickCount] >= 2) {
            _bridge->dpadX.store(0.0f, std::memory_order_relaxed);
            _bridge->dpadY.store(0.0f, std::memory_order_relaxed);
        } else {
            _draggingDpad = true;
            CGFloat dx = std::clamp((pt.x - NSMidX(_dpadRect)) / 54.0, -1.0, 1.0);
            CGFloat dy = std::clamp((pt.y - NSMidY(_dpadRect)) / 54.0, -1.0, 1.0);
            _bridge->dpadX.store(static_cast<float>(dx), std::memory_order_relaxed);
            _bridge->dpadY.store(static_cast<float>(dy), std::memory_order_relaxed);
        }
        [self setNeedsDisplay:YES];
        return;
    }

    // 5. Center CRT Tabs & Interactive Wave RAM / Tracker Arp Grid
    for (int t = 0; t < 3; ++t) {
        if (NSPointInRect(pt, _screenTabRects[t])) {
            _bridge->screenMode.store(t, std::memory_order_relaxed);
            [self setNeedsDisplay:YES];
            return;
        }
    }

    int screenMode = _bridge->screenMode.load(std::memory_order_relaxed);
    if (screenMode == 0 || screenMode == 1) {
        for (int i = 0; i < 6; ++i) {
            if (NSPointInRect(pt, _wavePresetBtnRects[i])) {
                [self applyWaveShapePreset:i];
                [self setNeedsDisplay:YES];
                return;
            }
        }
    } else if (screenMode == 2) {
        for (int i = 0; i < 6; ++i) {
            if (NSPointInRect(pt, _arpPresetBtnRects[i])) {
                [self setParamNorm:PixelBlaze::kParamArpPattern value:(i / 5.0f)];
                [self setParamNorm:PixelBlaze::kParamArpEnable value:1.0f];
                [self setNeedsDisplay:YES];
                return;
            }
        }
    }

    if (NSPointInRect(pt, _crtPlotRect)) {
        if (screenMode == 0) {
            _bridge->screenMode.store(1, std::memory_order_relaxed);
        } else if (screenMode == 1) {
            _draggingWaveRam = true;
            [self handleCrtDrag:pt];
        } else if (screenMode == 2) {
            _draggingArpGrid = true;
            [self handleCrtDrag:pt];
        }
        [self setNeedsDisplay:YES];
        return;
    }

    // 6. Right Arcade Deck: B (Glitch Randomizer), A (Fire Note), SELECT, START, Noise/Filter Modes
    if (NSPointInRect(pt, _btnBRect)) {
        _btnBPressed = true;
        _randSeed = _randSeed * 1664525u + 1013904223u + _frameCount;
        _bridge->randomizeGlitchPatch(_randSeed);
        for (uint32_t p = 0; p < PixelBlaze::kNumParams; ++p) {
            if (_callback) _callback->onGuiPerformEdit(p, _bridge->params[p].load(std::memory_order_relaxed));
        }
        [self setNeedsDisplay:YES];
        return;
    }
    if (NSPointInRect(pt, _btnARect)) {
        _btnAPressed = true;
        _bridge->pushUiNoteEvent(60, 0.92f, true);
        _bridge->pushUiNoteEvent(67, 0.85f, true);
        [self setNeedsDisplay:YES];
        return;
    }
    if (NSPointInRect(pt, _btnSelectRect)) {
        int curSkin = std::clamp(static_cast<int>(std::round(_bridge->params[PixelBlaze::kParamConsoleSkin].load() * 3.0f)), 0, 3);
        int nextSkin = (curSkin + 1) % 4;
        [self setParamNorm:PixelBlaze::kParamConsoleSkin value:(nextSkin / 3.0f)];
        [self setNeedsDisplay:YES];
        return;
    }
    if (NSPointInRect(pt, _btnStartRect)) {
        bool arpOn = _bridge->params[PixelBlaze::kParamArpEnable].load(std::memory_order_relaxed) >= 0.5f;
        [self setParamNorm:PixelBlaze::kParamArpEnable value:(arpOn ? 0.0f : 1.0f)];
        [self setNeedsDisplay:YES];
        return;
    }

    for (int i = 0; i < 3; ++i) {
        if (NSPointInRect(pt, _noiseModeRects[i])) {
            [self setParamNorm:PixelBlaze::kParamNoiseMode value:(i * 0.5f)];
            [self setNeedsDisplay:YES];
            return;
        }
        if (NSPointInRect(pt, _filterModeRects[i])) {
            [self setParamNorm:PixelBlaze::kParamFilterType value:(i * 0.5f)];
            [self setNeedsDisplay:YES];
            return;
        }
    }

    // 7. 18 Rotary Synth Knobs
    for (int i = 0; i < 18; ++i) {
        if (NSPointInRect(pt, _knobs[i].rect)) {
            if ([event clickCount] >= 2) {
                [self setParamNorm:_knobs[i].paramId value:PixelBlaze::kParamInfo[_knobs[i].paramId].defaultNorm];
            } else {
                _activeDragKnob = i;
                _dragStartY = pt.y;
                _dragStartVal = _bridge->params[_knobs[i].paramId].load(std::memory_order_relaxed);
                if (_callback) _callback->onGuiBeginEdit(_knobs[i].paramId);
            }
            [self setNeedsDisplay:YES];
            return;
        }
    }

    // 8. Pitch Wheel, Mod Wheel, Master Volume Knob
    if (NSPointInRect(pt, _pitchWheelRect)) {
        _draggingPitchWheel = true;
        float v = std::clamp(static_cast<float>((pt.y - _pitchWheelRect.origin.y) / _pitchWheelRect.size.height), 0.0f, 1.0f);
        [self setParamNorm:PixelBlaze::kParamPitchBend value:v];
        return;
    }
    if (NSPointInRect(pt, _modWheelRect)) {
        _draggingModWheel = true;
        float v = std::clamp(static_cast<float>((pt.y - _modWheelRect.origin.y) / _modWheelRect.size.height), 0.0f, 1.0f);
        [self setParamNorm:PixelBlaze::kParamModWheel value:v];
        return;
    }
    if (NSPointInRect(pt, _masterKnobRect)) {
        _draggingMasterKnob = true;
        _dragStartY = pt.y;
        _dragStartVal = _bridge->params[PixelBlaze::kParamMasterVolume].load(std::memory_order_relaxed);
        return;
    }

    // 9. On-Screen 3-Octave Chiptune Keyboard
    int hitPitch = [self pitchAtKeyboardPoint:pt];
    if (hitPitch >= 0) {
        _mouseHeldPitch = hitPitch;
        _bridge->pushUiNoteEvent(static_cast<int16_t>(hitPitch), 0.88f, true);
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDragged:(NSEvent*)event {
    NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];
    if (!_bridge) return;

    if (_activeDragKnob >= 0 && _activeDragKnob < 18) {
        uint32_t pid = _knobs[_activeDragKnob].paramId;
        float delta = static_cast<float>(pt.y - _dragStartY) / 130.0f;
        float newVal = std::clamp(_dragStartVal + delta, 0.0f, 1.0f);
        _bridge->params[pid].store(newVal, std::memory_order_relaxed);
        if (_callback) _callback->onGuiPerformEdit(pid, newVal);
        [self setNeedsDisplay:YES];
        return;
    }

    if (_draggingMasterKnob) {
        float delta = static_cast<float>(pt.y - _dragStartY) / 130.0f;
        float newVal = std::clamp(_dragStartVal + delta, 0.0f, 1.0f);
        [self setParamNorm:PixelBlaze::kParamMasterVolume value:newVal];
        [self setNeedsDisplay:YES];
        return;
    }

    if (_draggingDpad) {
        CGFloat dx = std::clamp((pt.x - NSMidX(_dpadRect)) / 54.0, -1.0, 1.0);
        CGFloat dy = std::clamp((pt.y - NSMidY(_dpadRect)) / 54.0, -1.0, 1.0);
        _bridge->dpadX.store(static_cast<float>(dx), std::memory_order_relaxed);
        _bridge->dpadY.store(static_cast<float>(dy), std::memory_order_relaxed);
        [self setNeedsDisplay:YES];
        return;
    }

    if (_draggingWaveRam || _draggingArpGrid) {
        [self handleCrtDrag:pt];
        return;
    }

    if (_draggingPitchWheel) {
        float v = std::clamp(static_cast<float>((pt.y - _pitchWheelRect.origin.y) / _pitchWheelRect.size.height), 0.0f, 1.0f);
        [self setParamNorm:PixelBlaze::kParamPitchBend value:v];
        [self setNeedsDisplay:YES];
        return;
    }

    if (_draggingModWheel) {
        float v = std::clamp(static_cast<float>((pt.y - _modWheelRect.origin.y) / _modWheelRect.size.height), 0.0f, 1.0f);
        [self setParamNorm:PixelBlaze::kParamModWheel value:v];
        [self setNeedsDisplay:YES];
        return;
    }

    if (_mouseHeldPitch >= 0) {
        int newPitch = [self pitchAtKeyboardPoint:pt];
        if (newPitch != _mouseHeldPitch) {
            _bridge->pushUiNoteEvent(static_cast<int16_t>(_mouseHeldPitch), 0.0f, false);
            if (newPitch >= 0) {
                _bridge->pushUiNoteEvent(static_cast<int16_t>(newPitch), 0.88f, true);
            }
            _mouseHeldPitch = newPitch;
            [self setNeedsDisplay:YES];
        }
    }
}

- (void)mouseUp:(NSEvent*)event {
    (void)event;
    if (_activeDragKnob >= 0 && _activeDragKnob < 18) {
        if (_callback) _callback->onGuiEndEdit(_knobs[_activeDragKnob].paramId);
        _activeDragKnob = -1;
    }
    _draggingMasterKnob = false;
    _draggingDpad = false;
    _draggingWaveRam = false;
    _draggingArpGrid = false;

    if (_draggingPitchWheel) {
        _draggingPitchWheel = false;
        [self setParamNorm:PixelBlaze::kParamPitchBend value:0.50f]; // Spring back pitch wheel
    }
    _draggingModWheel = false;

    if (_btnBPressed) {
        _btnBPressed = false;
    }
    if (_btnAPressed) {
        _btnAPressed = false;
        if (_bridge) {
            _bridge->pushUiNoteEvent(60, 0.0f, false);
            _bridge->pushUiNoteEvent(67, 0.0f, false);
        }
    }

    if (_mouseHeldPitch >= 0) {
        if (_bridge) {
            _bridge->pushUiNoteEvent(static_cast<int16_t>(_mouseHeldPitch), 0.0f, false);
        }
        _mouseHeldPitch = -1;
    }
    [self setNeedsDisplay:YES];
}

// Computer QWERTY Keyboard -> 8-Bit Chiptune MIDI Notes
- (int)midiNoteForKeyCode:(unsigned short)keyCode {
    switch (keyCode) {
        // Lower octave (Z..M -> C3..B3)
        case 6:  return 48; // Z -> C3
        case 1:  return 49; // S -> C#3
        case 7:  return 50; // X -> D3
        case 2:  return 51; // D -> D#3
        case 8:  return 52; // C -> E3
        case 9:  return 53; // V -> F3
        case 5:  return 54; // G -> F#3
        case 11: return 55; // B -> G3
        case 4:  return 56; // H -> G#3
        case 45: return 57; // N -> A3
        case 38: return 58; // J -> A#3
        case 46: return 59; // M -> B3
        // Upper octave (Q..I -> C4..C5)
        case 12: return 60; // Q -> C4
        case 19: return 61; // 2 -> C#4
        case 13: return 62; // W -> D4
        case 20: return 63; // 3 -> D#4
        case 14: return 64; // E -> E4
        case 15: return 65; // R -> F4
        case 23: return 66; // 5 -> F#4
        case 17: return 67; // T -> G4
        case 22: return 68; // 6 -> G#4
        case 16: return 69; // Y -> A4
        case 26: return 70; // 7 -> A#4
        case 32: return 71; // U -> B4
        case 34: return 72; // I -> C5
        default: return -1;
    }
}

- (void)keyDown:(NSEvent*)event {
    if ([event isARepeat]) return;
    int note = [self midiNoteForKeyCode:[event keyCode]];
    if (note >= 0 && _bridge) {
        _bridge->pushUiNoteEvent(static_cast<int16_t>(note), 0.88f, true);
        [self setNeedsDisplay:YES];
    }
}

- (void)keyUp:(NSEvent*)event {
    int note = [self midiNoteForKeyCode:[event keyCode]];
    if (note >= 0 && _bridge) {
        _bridge->pushUiNoteEvent(static_cast<int16_t>(note), 0.0f, false);
        [self setNeedsDisplay:YES];
    }
}

@end

// ============================================================================
// PixelBlazePlugView (Steinberg::IPlugView) implementation
// ============================================================================
namespace PixelBlaze {

PixelBlazePlugView::PixelBlazePlugView(SharedSynthBridge* b, IEditorParamCallback* cb)
    : bridge(b), callback(cb) {}

PixelBlazePlugView::~PixelBlazePlugView() {
    removed();
}

tresult PLUGIN_API PixelBlazePlugView::queryInterface(const TUID _iid, void** obj) {
    if (FUnknownPrivate::iidEqual(_iid, FUnknown::iid) ||
        FUnknownPrivate::iidEqual(_iid, IPlugView::iid)) {
        addRef();
        *obj = static_cast<IPlugView*>(this);
        return kResultOk;
    }
    *obj = nullptr;
    return kNoInterface;
}

uint32 PLUGIN_API PixelBlazePlugView::addRef() {
    return ++refCount;
}

uint32 PLUGIN_API PixelBlazePlugView::release() {
    uint32 r = --refCount;
    if (r == 0) delete this;
    return r;
}

tresult PLUGIN_API PixelBlazePlugView::isPlatformTypeSupported(FIDString type) {
    if (type && std::strcmp(type, kPlatformTypeNSView) == 0) {
        return kResultTrue;
    }
    return kResultFalse;
}

tresult PLUGIN_API PixelBlazePlugView::attached(void* parent, FIDString type) {
    if (!parent || isPlatformTypeSupported(type) != kResultTrue) {
        return kInvalidArgument;
    }
    removed();
    NSView* parentView = (__bridge NSView*)parent;
    NSRect frame = NSMakeRect(0, 0, kDefaultWidth, kDefaultHeight);
    PixelBlazeEditorView_v1* editor = [[PixelBlazeEditorView_v1 alloc] initWithFrame:frame bridge:bridge callback:callback];
    [parentView addSubview:editor];
    nativeNsView = (__bridge_retained void*)editor;
    return kResultOk;
}

tresult PLUGIN_API PixelBlazePlugView::removed() {
    if (nativeNsView) {
        PixelBlazeEditorView_v1* editor = (__bridge_transfer PixelBlazeEditorView_v1*)nativeNsView;
        [editor stopTimer];
        [editor removeFromSuperview];
        nativeNsView = nullptr;
    }
    return kResultOk;
}

tresult PLUGIN_API PixelBlazePlugView::onWheel(float distance) {
    (void)distance;
    return kResultOk;
}

tresult PLUGIN_API PixelBlazePlugView::onKeyDown(char16 key, int16 keyCode, int16 modifiers) {
    (void)key; (void)keyCode; (void)modifiers;
    return kResultOk;
}

tresult PLUGIN_API PixelBlazePlugView::onKeyUp(char16 key, int16 keyCode, int16 modifiers) {
    (void)key; (void)keyCode; (void)modifiers;
    return kResultOk;
}

tresult PLUGIN_API PixelBlazePlugView::getSize(ViewRect* size) {
    if (!size) return kInvalidArgument;
    *size = currentRect;
    return kResultOk;
}

tresult PLUGIN_API PixelBlazePlugView::onSize(ViewRect* newSize) {
    if (!newSize) return kInvalidArgument;
    currentRect = *newSize;
    return kResultOk;
}

tresult PLUGIN_API PixelBlazePlugView::onFocus(TBool state) {
    (void)state;
    return kResultOk;
}

tresult PLUGIN_API PixelBlazePlugView::setFrame(IPlugFrame* frame) {
    plugFrame = frame;
    return kResultOk;
}

tresult PLUGIN_API PixelBlazePlugView::canResize() {
    return kResultFalse;
}

tresult PLUGIN_API PixelBlazePlugView::checkSizeConstraint(ViewRect* rect) {
    if (!rect) return kInvalidArgument;
    rect->right = rect->left + kDefaultWidth;
    rect->bottom = rect->top + kDefaultHeight;
    return kResultOk;
}

void PixelBlazePlugView::notifyParamChangedFromHost() {
    if (nativeNsView) {
        PixelBlazeEditorView_v1* editor = (__bridge PixelBlazeEditorView_v1*)nativeNsView;
        [editor setNeedsDisplay:YES];
    }
}

void* createStandaloneEditorNsView(SharedSynthBridge* bridge, IEditorParamCallback* callback, int width, int height) {
    NSRect frame = NSMakeRect(0, 0, width, height);
    PixelBlazeEditorView_v1* view = [[PixelBlazeEditorView_v1 alloc] initWithFrame:frame bridge:bridge callback:callback];
    return (__bridge_retained void*)view;
}

void destroyStandaloneEditorNsView(void* nsViewPtr) {
    if (nsViewPtr) {
        PixelBlazeEditorView_v1* view = (__bridge_transfer PixelBlazeEditorView_v1*)nsViewPtr;
        [view stopTimer];
        [view removeFromSuperview];
    }
}

} // namespace PixelBlaze
