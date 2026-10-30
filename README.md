# MacBand

A simple macOS DAW: arrange patterns on a timeline, edit notes in a piano roll, host **Audio Unit** and **VST3** plugins.

## Build & run
```
./build.sh          # builds MacBand.app (release, ad-hoc signed)
open MacBand.app
```
Or `open Package.swift` in Xcode. Requires macOS 14+, Xcode 15+.

## Using it
- **Timeline** – `+` adds a track. Double-click empty track space to make a pattern; drag to move, drag the right edge to resize, ⌥-drag to copy, right-click for split/duplicate/delete.
- **Tempo lane** (under the ruler) – click to add a tempo change, drag to change BPM/position, double-click a point to make it glide from the previous tempo. The BPM display follows it during playback.
- **Loop** – drag in the thin strip above the ruler, press `L`.
- **Piano roll** (double-click a pattern) – Draw/Select/Erase tools (`P`/`V`/`E`), snap menu, scale highlighting, `⌘A/C/X/V/D`, arrows nudge/transpose, `Q` quantize. Right-click deletes a note.
- **Slide notes** – turn on **Slide** (or select notes and press `S`). A slide note glides the note sounding when it starts to the slide note's pitch, taking the slide note's length. Slides are sent as pitch bends, so set the track's **Slide range** (inspector) to match the instrument's bend range (built-in sounds use 12 semitones).
- **Lane under the roll** – *Velocity*, or *Volume Automation* (click to add points, drag to shape, right-click to remove). Automation is per pattern; 0 dB is the dashed line.
- **Mixer** tab – faders, pan, mute/solo, meters.
- **Musical typing** `⌘K`: A–L row plays notes, Z/X octave. MIDI keyboards work automatically. `R` records into the selected track.

## Vocal Tune (audio tracks)
Add an **Audio Track** (or drop/import an audio file, ⇧⌘I). MacBand then, automatically:
1. finds the pitch of the voice (YIN), 2. turns it into notes **locked to the nearest pitch** (or to your key/scale if one is set in the piano roll), 3. transcribes the words (on-device speech recognition, with word timings) and writes them on the notes.
The **Vocal Tune** tab shows them. With **Tune Off** the notes are slightly transparent and nothing is changed (red = the voice as sung, faint green = where tuning would put it). **Tune On** (or `T`) makes the notes opaque and plays the corrected voice (green curve).
- **Strength**: 0 = natural/untouched, 100 = every moment pulled onto the note (flat, robotic hard-tune).
- Drag a note up/down to change its pitch, drag its black end bar (or left edge) to resize, double-click a note to edit its word, double-click empty space to add a note, right-click for split/merge/delete.
- **Transition marker**: the small ring near a note's end. Drag it **left** (clock icon) to start the glide to the next note earlier = slower glide ("speed to match"); drag it **right** (pause icon) to make the correction wait before moving ("paused to match").
- **Chords**: give one word several pitches (`+`, right-click ▸ Add Another Pitch, or the **Chord** menu: major, minor, power, sus, 7ths, octave). The voice is shifted to each pitch and mixed in, one word becoming a chord. Dragging the word moves its chord; dragging an upper pitch moves just that voice.
- **Key**: pick a key and scale in the Key menu, then **Transpose Notes into This Key** (MacBand detects the vocal's key and moves every note and chord voice by the right amount, then pulls stray notes into the scale) or **Snap Out-of-Key Notes**.
- **Split**: cut a note into sections so each part can have its own pitch: right-click ▸ Split Here / Split Into 2–4 Sections, press `S` to cut selected notes at the playhead, or turn on the **Split Tool** and click notes to cut them. **Merge** joins them again. On the timeline, right-click an audio clip ▸ **Split Into Sections at Playhead** to divide the whole vocal; each section keeps its own tuning, strength and notes.
- **Move notes in time**: drag a note sideways to change which part of the vocal it corrects (it keeps its word, chord and transition marker, stops at neighbouring notes, and selected notes slide together). Drag vertically for pitch.
- **Words**: ⌘-drag a word onto another note and the two exchange. The **Words** menu (or ⌥← / ⌥→) slides the words one note left or right: all of them, or only the selected notes' words.
- **Selecting**: shift-click or drag a marquee to select several notes, then drag any of them to move them all (chord voices travel with their words). Tiny notes have a wider grab area; ⌥-drag a tiny note's left/right half to resize it.
- Record a vocal with the Record button (`R`) while an audio track is selected (needs microphone permission).
- Tuned audio is rendered in the background whenever you edit; export (WAV) and playback both use it. Audio is stored in `~/Library/Application Support/MacBand/Audio`, and saving a project also copies its audio to a “<name> Audio” folder beside the `.macband` file.
The app's main colour (selection boxes, loop, tuned notes, first track colour) follows your macOS accent colour.

## Plugins
Plugins are read from `~/Library/Audio/Plug-Ins` (Components = AU, VST3, VST) and `/Library/Audio/Plug-Ins`.
**Plugins ▸ Install Plugin…** (or drop a `.component`/`.vst3` on the window) copies it into the matching subfolder.
- VST2 (`.vst`) is not supported; Intel-only VST3s can't load in this arm64 app (their AU versions do, via macOS's out-of-process hosting).
- Plugins downloaded from the internet are quarantined by macOS; MacBand never loads them until you choose **Allow…** in the Plugin Manager.

## Files
- **Band project** `.macband` – File ▸ Save / Export Band Project, Import ▸ Band Project (merges tracks, plugin states included).
- **MIDI** – Import ▸ MIDI File (tracks, tempo map, time signature, CC7 → volume automation), Export ▸ MIDI File (slides become pitch bends, volume automation becomes CC7).
- **Audio** – Export ▸ Audio (WAV), 24-bit offline bounce.

## Developer checks
```
.build/debug/MacBand --tunetest                       # pitch tracking, note locking, retune, chord voices, strength
.build/debug/MacBand --audiotest                      # import → analyze → tune → export through a session
.build/debug/MacBand --transcribetest                 # speech-to-text with word timings
.build/debug/MacBand --selftest [plugin-name | vst3:plugin-name ...]   # audio pipeline, tempo, slides, loops, plugins
.build/debug/MacBand --uitest                                          # synthesized mouse/key events against the editors
.build/debug/MacBand --demo-plugin vst3:sylenth                        # open a plugin's window at launch
```
The VST3 host lives in `Sources/CVST3Host` (Objective-C++ wrapping Steinberg's MIT-licensed VST3 SDK as an `AUAudioUnit`).

## MeowSynth (bundled VST3)
`Plugins/MeowSynth.vst3` is a macOS VST3 instrument built from scratch (universal arm64 + x86_64): saw oscillator → high-resonance filter whose cutoff sweeps up and back down on every note, noise breath, ADSR, tempo-syncable vibrato with fade-in, portamento, chorus and a poly/mono "Polycat" switch. The editor shows a cat (two frames from `meow.mp4`) whose mouth opens with the filter sweep.
Rebuild with `Plugins/MeowSynth/build.sh`. Install it with **Plugins ▸ Install Plugin…** in MacBand, or copy it to `~/Library/Audio/Plug-Ins/VST3`.
