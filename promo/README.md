# Promo video

`docs/media/promo.mp4` is generated, not recorded:

- The frames were drawn by a SwiftPM renderer that reused the native Mac app's pedal, knob and LED views and the real
  effect catalog, with timing in beats so every animation lands on the music. It was retired together with the native
  Swift app; it is in git at the tag `native-mac-final` (`promo/renderer/`).
- `music.py`: the soundtrack, synthesized from scratch with numpy/scipy (drums, bass, chords, arps). No samples.

```bash
python3 music.py studio /tmp/studio.wav
```
