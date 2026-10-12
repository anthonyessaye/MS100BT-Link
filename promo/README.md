# Promo video

`docs/media/promo.mp4` is generated, not recorded:

- `renderer/`: a SwiftPM tool that draws each frame with the app's own pedal, knob and LED views
  (`AppControls.swift` is a copy of `MS100BTLinkApp/Controls.swift`) and the real effect catalog. Timing is in beats,
  so every animation lands on the music.
- `music.py`: the soundtrack, synthesized from scratch with numpy/scipy (drums, bass, chords, arps). No samples.

```bash
python3 music.py studio /tmp/studio.wav
cd renderer && swift build -c release
.build/release/PromoRenderer studio ../../MS100BTLink/Support/icon/icon-1024.png --video 30 \
  | ffmpeg -f rawvideo -pix_fmt rgba -s 1920x1080 -r 30 -i - -i /tmp/studio.wav \
      -map 0:v -map 1:a -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest ../out/promo.mp4
```

`--frame <beat> out.png` renders a single still for checking a scene.
