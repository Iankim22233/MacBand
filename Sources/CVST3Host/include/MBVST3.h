#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

/// An AUAudioUnit that hosts a VST3 plugin, so VST3 instruments and effects plug into
/// AVAudioEngine exactly like Audio Units.
@interface MBVST3AudioUnit : AUAudioUnit

/// Register a VST3 class so `AVAudioUnit.instantiate` can create it via `subtype`.
+ (BOOL)registerPluginAtPath:(NSString *)path
                     classID:(NSString *)classID
                        name:(NSString *)name
                  instrument:(BOOL)isInstrument
                     subtype:(UInt32)subtype;

/// Lists the audio classes in a .vst3 bundle: [{name, vendor, classID, instrument}].
+ (NSArray<NSDictionary *> *)scanBundleAtPath:(NSString *)path;

/// Transport info the plugin sees in its process context.
- (void)setHostTempo:(double)bpm beat:(double)beat playing:(BOOL)playing;

@end

NS_ASSUME_NONNULL_END
