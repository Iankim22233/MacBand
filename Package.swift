// swift-tools-version:5.9
import PackageDescription

// Steinberg VST3 SDK (MIT) sources needed to host VST3 plugins.
let sdk = "vst3sdk"
let sdkSources: [String] = [
    "pluginterfaces/base/funknown.cpp",
    "pluginterfaces/base/coreiids.cpp",
    "pluginterfaces/base/ustring.cpp",
    "pluginterfaces/base/conststringtable.cpp",
    "base/source/baseiids.cpp",
    "base/source/fobject.cpp",
    "base/source/fstring.cpp",
    "base/source/fdebug.cpp",
    "base/source/fbuffer.cpp",
    "base/source/updatehandler.cpp",
    "base/source/fstreamer.cpp",
    "public.sdk/source/common/commoniids.cpp",
    "public.sdk/source/common/memorystream.cpp",
    "public.sdk/source/common/commonstringconvert.cpp",
    "public.sdk/source/common/threadchecker_mac.mm",
    "base/thread/source/flock.cpp",
    "public.sdk/source/vst/vstinitiids.cpp",
    "public.sdk/source/vst/hosting/module.cpp",
    "public.sdk/source/vst/hosting/module_mac.mm",
    "public.sdk/source/vst/hosting/hostclasses.cpp",
    "public.sdk/source/vst/hosting/eventlist.cpp",
    "public.sdk/source/vst/hosting/parameterchanges.cpp",
    "public.sdk/source/vst/hosting/processdata.cpp",
    "public.sdk/source/vst/hosting/pluginterfacesupport.cpp",
    "public.sdk/source/vst/hosting/connectionproxy.cpp",
    "public.sdk/source/vst/utility/stringconvert.cpp",
].map { "\(sdk)/\($0)" }

let package = Package(
    name: "MacBand",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CVST3Host",
            path: "Sources/CVST3Host",
            exclude: [
                "vst3sdk/CMakeLists.txt", "vst3sdk/README.md", "vst3sdk/LICENSE.txt",
            ],
            sources: ["MBVST3AudioUnit.mm"] + sdkSources,
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("vst3sdk"),
                .define("RELEASE", to: "1"),
                .unsafeFlags(["-fobjc-arc", "-std=c++17", "-Wno-deprecated-declarations", "-Wno-unused-parameter"]),
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"), .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"), .linkedFramework("CoreAudioKit"), .linkedFramework("CoreMIDI"),
            ]
        ),
        .executableTarget(
            name: "MacBand",
            dependencies: ["CVST3Host"],
            path: "Sources/MacBand",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/Embedded-Info.plist"])]
        ),
    ]
)
