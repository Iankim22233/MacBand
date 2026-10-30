#!/bin/bash
# Builds SF2Player.vst3 (universal arm64 + x86_64) into ../SF2Player.vst3
set -euo pipefail
cd "$(dirname "$0")"
SDK="../../Sources/CVST3Host/vst3sdk"
OUT="../SF2Player.vst3"
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
for arch in arm64 x86_64; do
  mkdir -p "$OBJ/$arch"; pids=()
  for f in "${SRC[@]}"; do
    clang++ -arch "$arch" "${FLAGS[@]}" -c "$SDK/$f" -o "$OBJ/$arch/$(echo "$f" | tr '/' '_').o" & pids+=($!)
  done
  clang++ -arch "$arch" "${FLAGS[@]}" -x objective-c++ -c SF2UI.mm -o "$OBJ/$arch/SF2UI.o" & pids+=($!)
  clang++ -arch "$arch" "${FLAGS[@]}" -x objective-c++ -c SF2PlayerVST3.mm -o "$OBJ/$arch/SF2PlayerVST3.o" & pids+=($!)
  for p in "${pids[@]}"; do wait "$p"; done
  clang++ -arch "$arch" -bundle -o "$OBJ/SF2Player.$arch" "$OBJ/$arch"/*.o -framework Cocoa -framework CoreFoundation -framework UniformTypeIdentifiers
done
rm -rf "$OUT"; mkdir -p "$OUT/Contents/MacOS"
lipo -create "$OBJ"/SF2Player.arm64 "$OBJ"/SF2Player.x86_64 -output "$OUT/Contents/MacOS/SF2Player"
cp Info-VST3.plist "$OUT/Contents/Info.plist"; echo -n "BNDL????" > "$OUT/Contents/PkgInfo"
codesign --force --sign - "$OUT"; rm -rf "$OBJ"
echo "Built $(cd .. && pwd)/SF2Player.vst3"
