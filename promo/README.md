# Promo video

`docs/media/promo.mp4` is generated, not recorded:

- `renderer/`: a SwiftPM tool that draws every frame in SwiftUI with the app's pedal, knob and LED drawing
  (`AppControls.swift`), plus flat illustrations (`People.swift`: a guitarist with a Bluetooth footswitch, a hand on a
  phone, the Mac and Android apps). Timing is in beats, so every animation lands on the music. Scenes and their
  lengths are in `Scenes.swift` (`Timeline`).
- `music.py`: the soundtrack, synthesized from scratch with numpy/scipy (drums, bass, chords, arps). No samples. Its
  bar markers (`BEATS`, `OUTRO_BAR`…) follow the timeline.

```bash
swift ../apps/ms100bt_link/tool/make-icon.swift /tmp/icon.png mac
python3 music.py studio /tmp/studio.wav
cd renderer && swift build -c release
.build/release/PromoRenderer studio /tmp/icon.png --video 30 \
  | ffmpeg -f rawvideo -pix_fmt rgba -s 1920x1080 -r 30 -i - -i /tmp/studio.wav \
      -map 0:v -map 1:a -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest ../out/promo.mp4
```

`--frame <beat> out.png` renders a single still for checking a scene.
