#pragma once
#import <Cocoa/Cocoa.h>
#include <functional>
#include <memory>
#include "SF2Core.h"

/// The editor shared by the VST3 and the AU: file loader, searchable preset list, audition keyboard,
/// and a few parameter sliders.
@interface SF2EditorView : NSView
/// `edit(paramID, plainValue)` is called when the user moves a slider, so the host can record it.
- (instancetype)initWithCore:(std::shared_ptr<SF2Plugin::Core>)core edit:(std::function<void(uint32_t, double)>)edit;
- (void)shutdown;
@end
