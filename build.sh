#!/bin/zsh
set -e

cd "$(dirname "$0")"

VST_BUNDLE="build/Pixel-Blaze 1999.vst3"
APP_BUNDLE="build/Pixel-Blaze 1999.app"

mkdir -p "$VST_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

echo "[1/5] Generating macOS AppIcon.icns for Pixel-Blaze 1999.app..."
clang++ -std=c++17 -O2 -isysroot "$SDK_PATH" -fobjc-arc src/generate_icon.mm -framework Cocoa -o build/generate_icon
./build/generate_icon build/icon_1024.png

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16     build/icon_1024.png --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     build/icon_1024.png --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     build/icon_1024.png --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     build/icon_1024.png --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   build/icon_1024.png --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   build/icon_1024.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   build/icon_1024.png --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   build/icon_1024.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   build/icon_1024.png --out "$ICONSET/icon_512x512.png"    >/dev/null
cp build/icon_1024.png "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
echo "[OK] Generated AppIcon.icns"

cat > "$VST_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>CFBundleExecutable</key>
    <string>PixelBlaze1999</string>
    <key>CFBundleIdentifier</key>
    <string>com.pixelblaze.pixelblaze1999.vst3</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Pixel-Blaze 1999</string>
    <key>CFBundleDisplayName</key>
    <string>Pixel-Blaze 1999</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CSResourcesFileMapped</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

printf "BNDL????" > "$VST_BUNDLE/Contents/PkgInfo"

echo "[2/5] Compiling Universal Binary (x86_64 + arm64) VST3 bundle..."
clang++ -std=c++17 -O3 -fPIC -bundle \
    -isysroot "$SDK_PATH" \
    -arch x86_64 -arch arm64 \
    -mmacosx-version-min=11.0 \
    -fobjc-arc \
    -I. \
    -Wno-deprecated-declarations \
    src/PixelBlazePlugin.cpp \
    src/PixelBlazeGUI.mm \
    pluginterfaces/base/funknown.cpp \
    pluginterfaces/base/conststringtable.cpp \
    -framework Cocoa \
    -framework QuartzCore \
    -framework CoreFoundation \
    -o "$VST_BUNDLE/Contents/MacOS/PixelBlaze1999"

codesign --force --deep --sign - "$VST_BUNDLE"
echo "[OK] Built and signed $VST_BUNDLE"

echo "[3/5] Compiling Standalone Desktop App ($APP_BUNDLE)..."
cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PixelBlaze1999</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.pixelblaze.pixelblaze1999.standalone</string>
    <key>CFBundleName</key>
    <string>Pixel-Blaze 1999</string>
    <key>CFBundleDisplayName</key>
    <string>Pixel-Blaze 1999</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

clang++ -std=c++17 -O3 \
    -isysroot "$SDK_PATH" \
    -arch x86_64 -arch arm64 \
    -mmacosx-version-min=11.0 \
    -fobjc-arc \
    -I. \
    -Wno-deprecated-declarations \
    src/standalone_main.mm \
    src/PixelBlazeGUI.mm \
    pluginterfaces/base/funknown.cpp \
    pluginterfaces/base/conststringtable.cpp \
    -framework Cocoa \
    -framework QuartzCore \
    -framework AudioToolbox \
    -framework CoreMIDI \
    -framework CoreFoundation \
    -o "$APP_BUNDLE/Contents/MacOS/PixelBlaze1999"

codesign --force --deep --sign - "$APP_BUNDLE"
echo "[OK] Built and signed $APP_BUNDLE"

echo "[4/5] Compiling VST3 Host Validator & Audio/GUI Test..."
clang++ -std=c++17 -O2 \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min=11.0 \
    -fobjc-arc \
    -I. \
    -Wno-deprecated-declarations \
    src/test_vst3_host.mm \
    pluginterfaces/base/funknown.cpp \
    pluginterfaces/base/conststringtable.cpp \
    -framework Cocoa \
    -framework CoreFoundation \
    -o build/test_vst3_host

echo "[5/5] Running VST3 Host Validation & Audio Render Test..."
./build/test_vst3_host "$VST_BUNDLE" build/preview_nes_scope.png build/pixelblaze_demo.wav
