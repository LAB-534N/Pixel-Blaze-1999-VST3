#!/bin/zsh
set -e

cd "$(dirname "$0")"

VST_SRC="build/Pixel-Blaze 1999.vst3"
VST_DST="$HOME/Library/Audio/Plug-Ins/VST3/Pixel-Blaze 1999.vst3"

if [ ! -d "$VST_SRC" ]; then
    echo "Building Pixel-Blaze 1999 first..."
    ./build.sh
fi

mkdir -p "$HOME/Library/Audio/Plug-Ins/VST3"
rm -rf "$VST_DST"
cp -R "$VST_SRC" "$VST_DST"
codesign --force --deep --sign - "$VST_DST"

echo "========================================================"
echo "INSTALLED: $VST_DST"
echo "In FL Studio: Options -> Manage plugins -> Find installed plugins"
echo "========================================================"
