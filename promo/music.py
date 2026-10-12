"""Original soundtrack for the MS-100BT Link promo, synthesized from scratch (no samples).

Usage: python3 music.py <studio|neon> <out.wav>

studio: 124 BPM house groove in A minor (Am F C G), sidechained pads and stabs, pluck arp.
neon:   104 BPM synthwave in F# minor (F#m D A E), gated arps, big pads, octave bass.

The arrangement follows the video's 138-beat timeline (bars of 4 beats; scenes in renderer/Scenes.swift):
  bars 0-1 intro, 2 drop (the guitarist), 6 arp joins (pedalboard), 20 breakdown + riser,
  21 second drop with the lead (AI scene), 32 final hit (outro), then the tail fades.
"""
import sys
import numpy as np
from scipy.signal import butter, lfilter

SR = 44100
rng = np.random.default_rng(7)


def note_hz(n):  # MIDI note → Hz
    return 440.0 * 2 ** ((n - 69) / 12)


def lp(x, cutoff, order=2):
    b, a = butter(order, min(cutoff, SR * 0.45) / (SR / 2), "low")
    return lfilter(b, a, x)


def hp(x, cutoff, order=2):
    b, a = butter(order, cutoff / (SR / 2), "high")
    return lfilter(b, a, x)


def env(n, attack, decay_tau, release=0.01):
    t = np.arange(n) / SR
    e = np.minimum(t / max(attack, 1e-4), 1.0) * np.exp(-np.maximum(t - attack, 0) / decay_tau)
    r = int(release * SR)
    if r and n > r:
        e[-r:] *= np.linspace(1, 0, r)
    return e


def saw(freq, n, detune_cents=(0,)):
    t = np.arange(n) / SR
    out = np.zeros(n)
    for c in detune_cents:
        f = freq * 2 ** (c / 1200)
        out += 2 * ((t * f + rng.random()) % 1.0) - 1
    return out / len(detune_cents)


def square(freq, n):
    t = np.arange(n) / SR
    return np.sign(np.sin(2 * np.pi * freq * t))


class Track:
    def __init__(self, bpm, beats, tail=3.0):
        self.bpm = bpm
        self.beat = 60.0 / bpm
        self.n = int((beats * self.beat + tail) * SR)
        self.L = np.zeros(self.n)
        self.R = np.zeros(self.n)
        self.kicks = []  # beat positions (for sidechain)

    def add_stereo(self, left, right, at_beat, gain=1.0):
        i = int(at_beat * self.beat * SR)
        if i >= self.n:
            return
        m = min(len(left), self.n - i)
        self.L[i:i + m] += left[:m] * gain
        self.R[i:i + m] += right[:m] * gain

    def add(self, sig, at_beat, gain=1.0, pan=0.0):
        i = int(at_beat * self.beat * SR)
        if i >= self.n:
            return
        sig = sig[: self.n - i] * gain
        self.L[i:i + len(sig)] += sig * np.sqrt(0.5 * (1 - pan))
        self.R[i:i + len(sig)] += sig * np.sqrt(0.5 * (1 + pan))

    # --- instruments -------------------------------------------------------
    def kick(self, b, gain=1.0):
        n = int(0.45 * SR)
        t = np.arange(n) / SR
        f = 45 + 110 * np.exp(-t * 28)
        ph = 2 * np.pi * np.cumsum(f) / SR
        s = np.sin(ph) * np.exp(-t * 7.5) + 0.3 * np.sin(ph) * np.exp(-t * 60)
        click = hp(rng.standard_normal(n), 3000) * np.exp(-t * 300) * 0.15
        self.add(np.tanh(1.6 * (s + click)), b, gain)
        self.kicks.append(b)

    def clap(self, b, gain=0.5):
        n = int(0.3 * SR)
        t = np.arange(n) / SR
        noise = hp(lp(rng.standard_normal(n), 7000), 900)
        e = np.exp(-t * 22)
        for k, d in enumerate((0, 0.011, 0.022)):  # three quick hits
            e += 0.6 * np.exp(-np.maximum(t - d, 0) * 90) * (t >= d)
        self.add(noise * e * 0.6, b, gain, pan=0.05)

    def hat(self, b, open_=False, gain=0.18, pan=0.25):
        n = int((0.22 if open_ else 0.05) * SR)
        t = np.arange(n) / SR
        s = hp(rng.standard_normal(n), 8000) * np.exp(-t * (14 if open_ else 70))
        self.add(s, b, gain, pan)

    def crash(self, b, gain=0.35):
        n = int(2.8 * SR)
        t = np.arange(n) / SR
        s = hp(rng.standard_normal(n), 4000) * np.exp(-t * 1.6)
        self.add(s, b, gain, pan=-0.2)
        self.add(hp(rng.standard_normal(n), 4500) * np.exp(-t * 1.7), b, gain * 0.8, pan=0.3)

    def riser(self, b, beats, gain=0.25):
        n = int(beats * self.beat * SR)
        t = np.linspace(0, 1, n)
        s = rng.standard_normal(n)
        # rising band: blend of progressively brighter noise
        s = lp(s, 600) * (1 - t) + hp(s, 2500) * t
        self.add(s * t ** 2, b, gain)

    def bass(self, b, note, dur_beats, gain=0.45, cutoff=600, kind="saw"):
        n = int(dur_beats * self.beat * SR)
        f = note_hz(note)
        osc = saw(f, n, (0, 7)) if kind == "saw" else square(f, n) * 0.7
        osc += 0.6 * np.sin(2 * np.pi * f / 2 * np.arange(n) / SR)  # sub
        s = lp(osc, cutoff) * env(n, 0.004, dur_beats * self.beat * 0.9, 0.02)
        self.add(s, b, gain)

    def pad(self, b, notes, dur_beats, gain=0.18, cutoff=2200, attack=0.4):
        n = int(dur_beats * self.beat * SR)
        e = env(n, attack, 20, 0.4)
        # independent voices per side (different detune and phases) = real stereo width
        left = sum(saw(note_hz(nt), n, (-13, 2, 9)) for nt in notes) / len(notes)
        right = sum(saw(note_hz(nt), n, (-7, -2, 12)) for nt in notes) / len(notes)
        self.add_stereo(lp(left, cutoff) * e, lp(right, cutoff) * e, b, gain * 0.75)

    def stab(self, b, notes, gain=0.22, cutoff=3500):
        n = int(0.35 * SR)
        s = sum(saw(note_hz(nt), n, (-8, 8)) for nt in notes) / len(notes)
        s = lp(s, cutoff) * env(n, 0.003, 0.09, 0.02)
        self.add(s, b, gain, pan=0.1)

    def pluck(self, b, note, gain=0.2, pan=0.3, decay=0.12, cutoff=5000, kind="saw"):
        n = int(0.5 * SR)
        f = note_hz(note)
        osc = saw(f, n, (-6, 6)) if kind == "saw" else square(f, n)
        s = lp(osc, cutoff) * env(n, 0.002, decay, 0.02)
        self.add(s, b, gain, pan)
        self.add(lp(s, 2500) * 0.4, b + 0.75, gain, -pan)  # dotted-eighth echo on the other side

    def lead(self, b, note, dur_beats, gain=0.16, cutoff=4500):
        n = int(dur_beats * self.beat * SR)
        t = np.arange(n) / SR
        f = note_hz(note) * (1 + 0.004 * np.sin(2 * np.pi * 5.5 * t) * np.minimum(t / 0.3, 1))  # vibrato
        ph = 2 * np.pi * np.cumsum(f) / SR
        osc = 2 * ((ph / (2 * np.pi)) % 1) - 1
        osc = 0.6 * osc + 0.4 * np.sign(np.sin(ph))
        s = lp(osc, cutoff) * env(n, 0.01, 3, 0.08)
        self.add(s, b, gain, 0.0)
        self.add(np.concatenate([np.zeros(int(0.375 * self.beat * SR * 2)), s])[:n] * 0.3, b, gain, 0.4)

    # --- mix ---------------------------------------------------------------
    def sidechain(self, depth=0.55):
        """Pump everything except drums would need buses; approximate on the full mix lightly."""
        g = np.ones(self.n)
        for b in self.kicks:
            i = int(b * self.beat * SR)
            m = min(int(0.25 * SR), self.n - i)
            if m > 0:
                t = np.arange(m) / SR
                g[i:i + m] = np.minimum(g[i:i + m], 1 - depth * np.exp(-t * 14))
        return g

    def render(self, path, music_gain=1.0):
        mix = np.stack([self.L, self.R], axis=1) * music_gain
        mix = np.tanh(mix * 1.15)                    # glue / soft clip
        mix /= np.max(np.abs(mix)) / 0.89            # about -1 dBFS
        fade = int(1.5 * SR)
        mix[-fade:] *= np.linspace(1, 0, fade)[:, None]
        pcm = (mix * 32767).astype(np.int16)
        import wave
        with wave.open(path, "wb") as w:
            w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
            w.writeframes(pcm.tobytes())


BEATS = 138
ARP_BAR, BREAKDOWN_BAR, DROP2_BARS, OUTRO_BAR = 6, 20, range(21, 25), 32


def build(style):
    if style == "studio":
        bpm, root = 124, 57  # A3
        prog = [(57, [57, 60, 64]), (53, [53, 57, 60]), (48, [48, 52, 55]), (55, [55, 59, 62])]  # Am F C G
        arp_shape = [0, 12, 7, 12, 3, 12, 7, 15]
        lead_line = [76, None, 72, 74, 76, None, 79, 76, 74, None, 72, 71, 72, None, 69, None]
    else:
        bpm, root = 104, 54  # F#3
        prog = [(54, [54, 57, 61]), (50, [50, 54, 57]), (57, [57, 61, 64]), (52, [52, 56, 59])]  # F#m D A E
        arp_shape = [0, 7, 12, 7, 15, 12, 7, 12]
        lead_line = [73, None, 76, 78, 76, None, 73, 71, 69, None, 71, 73, 76, None, 73, None]

    tr = Track(bpm, BEATS, tail=3.0)
    bars = int(np.ceil(BEATS / 4))
    pads = Track(bpm, BEATS, tail=3.0)  # separate bus so pads/bass can pump against the kick

    for bar in range(bars):
        b0 = bar * 4
        chord_root, chord = prog[bar % 4]
        intro = bar < 2
        breakdown = bar == BREAKDOWN_BAR
        outro = bar >= OUTRO_BAR
        full = not (intro or breakdown or outro)
        drop2 = bar in DROP2_BARS

        # pads: always (longer in intro/outro)
        if bar < OUTRO_BAR + 1:
            pads.pad(b0, [n + 12 for n in chord] + [chord_root], 4 if not outro else 8,
                     gain=0.16 if full else 0.22, cutoff=1200 if intro else 2400, attack=0.6 if intro else 0.08)

        if full:
            for k in range(4):
                tr.kick(b0 + k)
            tr.clap(b0 + 1); tr.clap(b0 + 3)
            for k in range(8):
                tr.hat(b0 + k * 0.5 + 0.5, open_=(k % 2 == 0), gain=0.14 if k % 2 == 0 else 0.1, pan=0.45 if k % 2 else -0.3)
            if style == "studio":
                # offbeat house bass + chord stabs
                for k in range(4):
                    pads.bass(b0 + k + 0.5, chord_root - 24 + (12 if k == 3 else 0), 0.45, gain=0.5, cutoff=420)
                for off in (0.5, 1.75, 2.5, 3.75):
                    pads.stab(b0 + off, [n + 12 for n in chord], gain=0.16)
            else:
                # driving 8th-note octave bass
                for k in range(8):
                    pads.bass(b0 + k * 0.5, chord_root - 24 + (12 if k % 2 else 0), 0.48, gain=0.42, cutoff=700, kind="saw")
                for k in range(16):
                    tr.hat(b0 + k * 0.25, gain=0.05, pan=-0.3)
            if bar >= ARP_BAR:
                for k, step in enumerate(arp_shape * 2):
                    tr.pluck(b0 + k * 0.25, chord_root + 12 + step, gain=0.11 if style == "studio" else 0.1,
                             pan=0.6 if k % 2 else -0.6, kind="saw" if style == "studio" else "square",
                             cutoff=4200 if style == "studio" else 3000)
            if drop2:
                for k, nt in enumerate(lead_line):
                    if nt is not None:
                        tr.lead(b0 + k * 0.25 if style == "neon" else b0 + k * 0.25, nt, 0.5, gain=0.13)

        if intro:
            for k in range(8):
                tr.hat(b0 + k * 0.5, gain=0.05 + 0.02 * bar, pan=0.3)
        if bar == 1:
            tr.riser(b0, 4, gain=0.22)
        if breakdown:
            tr.riser(b0, 4, gain=0.28)
            for k in range(4):
                tr.clap(b0 + 2 + k * 0.5, gain=0.18 + 0.08 * k)  # snare roll into the drop

    # impacts on the big moments
    end = OUTRO_BAR * 4
    for b in (8, (BREAKDOWN_BAR + 1) * 4):
        tr.crash(b)
    tr.kick(end, gain=1.1); tr.crash(end, gain=0.45)
    tr.stab(end, [n + 12 for n in prog[0][1]] + [prog[0][0]], gain=0.35, cutoff=5000)
    pads.pad(end, [n + 12 for n in prog[0][1]] + [prog[0][0], prog[0][0] + 24], 10, gain=0.3, cutoff=3000, attack=0.02)

    duck = tr.sidechain(depth=0.6 if style == "studio" else 0.45)
    tr.L += pads.L * duck
    tr.R += pads.R * duck
    return tr


if __name__ == "__main__":
    style, out = sys.argv[1], sys.argv[2]
    build(style).render(out)
    print("wrote", out)
