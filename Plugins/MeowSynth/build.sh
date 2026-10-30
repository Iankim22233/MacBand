#!/bin/bash
# Builds MeowSynth.vst3 (universal arm64 + x86_64) into ../MeowSynth.vst3
set -euo pipefail
cd "$(dirname "$0")"
SDK="../../Sources/CVST3Host/vst3sdk"
OUT="../MeowSynth.vst3"
OBJ="$(mktemp -d)"
SRC=(
  pluginterfaces/base/funknown.cpp pluginterfaces/base/coreiids.cpp pluginterfaces/base/ustring.cpp pluginterfaces/base/conststringtable.cpp
  base/source/baseiids.cpp base/source/fobject.cpp base/source/fstring.cpp base/source/fdebug.cpp base/source/fbuffer.cpp
  base/source/updatehandler.cpp base/source/fstreamer.cpp base/thread/source/flock.cpp
  public.sdk/source/common/commoniids.cpp public.sdk/source/common/pluginview.cpp
  public.sdk/source/vst/vstinitiids.cpp public.sdk/source/vst/vstaudioeffect.cpp public.sdk/source/vst/vstcomponent.cpp
  public.sdk/source/vst/vstcomponentbase.cpp public.sdk/source/vst/vsteditcontroller.cpp public.sdk/source/vst/vstbus.cpp
  public.sdk/source/vst/vstparameters.cpp
)
FLAGS=(-std=c++17 -O2 -fvisibility=hidden -fobjc-arc -DRELEASE=1 -I"$SDK" -I. -Wno-deprecated-declarations -Wno-unused-parameter -mmacosx-version-min=11.0)
ARCHS=(arm64 x86_64)
for arch in "${ARCHS[@]}"; do
  mkdir -p "$OBJ/$arch"
  pids=()
  for f in "${SRC[@]}"; do
    o="$OBJ/$arch/$(echo "$f" | tr '/' '_').o"
    clang++ -arch "$arch" "${FLAGS[@]}" -c "$SDK/$f" -o "$o" &
    pids+=($!)
  done
  clang++ -arch "$arch" "${FLAGS[@]}" -x objective-c++ -c MeowSynth.mm -o "$OBJ/$arch/MeowSynth.o" &
  pids+=($!)
  for p in "${pids[@]}"; do wait "$p"; done
  clang++ -arch "$arch" -bundle -o "$OBJ/MeowSynth.$arch" "$OBJ/$arch"/*.o -framework Cocoa -framework CoreFoundation
done
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
lipo -create "$OBJ"/MeowSynth.arm64 "$OBJ"/MeowSynth.x86_64 -output "$OUT/Contents/MacOS/MeowSynth"
cp Info.plist "$OUT/Contents/Info.plist"
mkdir -p "$OUT/Contents/Resources"
cp Resources/*.png "$OUT/Contents/Resources/"
echo -n "BNDL????" > "$OUT/Contents/PkgInfo"
codesign --force --sign - "$OUT"
rm -rf "$OBJ"
echo "Built $(cd .. && pwd)/MeowSynth.vst3"
