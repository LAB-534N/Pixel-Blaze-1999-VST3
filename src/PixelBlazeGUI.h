#pragma once

#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "PixelBlazeParams.h"
#include <atomic>

namespace PixelBlaze {

class IEditorParamCallback {
public:
    virtual ~IEditorParamCallback() = default;
    virtual void onGuiBeginEdit(uint32_t paramId) = 0;
    virtual void onGuiPerformEdit(uint32_t paramId, double normalizedValue) = 0;
    virtual void onGuiEndEdit(uint32_t paramId) = 0;
    virtual void onGuiPresetSelected(int presetIndex) = 0;
};

class PixelBlazePlugView : public Steinberg::IPlugView {
public:
    PixelBlazePlugView(SharedSynthBridge* bridge, IEditorParamCallback* callback);
    virtual ~PixelBlazePlugView();

    // FUnknown
    Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID _iid, void** obj) override;
    Steinberg::uint32 PLUGIN_API addRef() override;
    Steinberg::uint32 PLUGIN_API release() override;

    // IPlugView
    Steinberg::tresult PLUGIN_API isPlatformTypeSupported(Steinberg::FIDString type) override;
    Steinberg::tresult PLUGIN_API attached(void* parent, Steinberg::FIDString type) override;
    Steinberg::tresult PLUGIN_API removed() override;
    Steinberg::tresult PLUGIN_API onWheel(float distance) override;
    Steinberg::tresult PLUGIN_API onKeyDown(Steinberg::char16 key, Steinberg::int16 keyCode, Steinberg::int16 modifiers) override;
    Steinberg::tresult PLUGIN_API onKeyUp(Steinberg::char16 key, Steinberg::int16 keyCode, Steinberg::int16 modifiers) override;
    Steinberg::tresult PLUGIN_API getSize(Steinberg::ViewRect* size) override;
    Steinberg::tresult PLUGIN_API onSize(Steinberg::ViewRect* newSize) override;
    Steinberg::tresult PLUGIN_API onFocus(Steinberg::TBool state) override;
    Steinberg::tresult PLUGIN_API setFrame(Steinberg::IPlugFrame* frame) override;
    Steinberg::tresult PLUGIN_API canResize() override;
    Steinberg::tresult PLUGIN_API checkSizeConstraint(Steinberg::ViewRect* rect) override;

    void notifyParamChangedFromHost();

    static constexpr int kDefaultWidth = 1040;
    static constexpr int kDefaultHeight = 680;

private:
    std::atomic<Steinberg::uint32> refCount{1};
    SharedSynthBridge* bridge = nullptr;
    IEditorParamCallback* callback = nullptr;
    Steinberg::IPlugFrame* plugFrame = nullptr;
    Steinberg::ViewRect currentRect{0, 0, kDefaultWidth, kDefaultHeight};
    void* nativeNsView = nullptr;
};

// Standalone macOS app helper to attach the exact same Console Hardware GUI
void* createStandaloneEditorNsView(SharedSynthBridge* bridge, IEditorParamCallback* callback, int width, int height);
void destroyStandaloneEditorNsView(void* nsViewPtr);

} // namespace PixelBlaze
