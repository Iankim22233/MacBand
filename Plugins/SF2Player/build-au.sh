#!/bin/bash
# Builds SF2Player.component (universal arm64 + x86_64) into ../SF2Player.component
set -euo pipefail
cd "$(dirname "$0")"
SDK="ThirdParty/AudioUnitSDK"
OUT="../SF2Player.component"
OBJ="$(mktemp -d)"
SDKSRC=(AUBase AUBuffer AUBufferAllocator AUInputElement AUMIDIBase AUOutputElement AUPlugInDispatch AUScopeElement ComponentBase MusicDeviceBase)
FLAGS=(-std=c++2b -O2 -fvisibility=hidden -fobjc-arc -I"$SDK/include" -I. -Wno-deprecated-declarations -Wno-unused-parameter -mmacosx-version-min=11.0)
for arch in arm64 x86_64; do
  mkdir -p "$OBJ/$arch"; pids=()
  for f in "${SDKSRC[@]}"; do clang++ -arch "$arch" "${FLAGS[@]}" -c "$SDK/src/AudioUnitSDK/$f.cpp" -o "$OBJ/$arch/$f.o" & pids+=($!); done
  clang++ -arch "$arch" "${FLAGS[@]}" -x objective-c++ -c SF2UI.mm -o "$OBJ/$arch/SF2UI.o" & pids+=($!)
  clang++ -arch "$arch" "${FLAGS[@]}" -x objective-c++ -c SF2PlayerAU.mm -o "$OBJ/$arch/SF2PlayerAU.o" & pids+=($!)
  for p in "${pids[@]}"; do wait "$p"; done
  clang++ -arch "$arch" -bundle -o "$OBJ/SF2Player.$arch" "$OBJ/$arch"/*.o -framework Cocoa -framework CoreAudioKit -framework AudioToolbox -framework CoreAudio -framework CoreFoundation -framework UniformTypeIdentifiers
done
rm -rf "$OUT"; mkdir -p "$OUT/Contents/MacOS"
lipo -create "$OBJ"/SF2Player.arm64 "$OBJ"/SF2Player.x86_64 -output "$OUT/Contents/MacOS/SF2Player"
cp Info-AU.plist "$OUT/Contents/Info.plist"; echo -n "BNDL????" > "$OUT/Contents/PkgInfo"
codesign --force --sign - "$OUT"; rm -rf "$OBJ"
echo "Built $(cd .. && pwd)/SF2Player.component"
