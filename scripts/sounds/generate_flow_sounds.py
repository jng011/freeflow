#!/usr/bin/env python3
"""Generate the original Flow sound packs.

Every sound is synthesized from scratch with numpy (sines, filtered noise,
simple delays). Nothing is decoded, resampled or copied from any other app.
The recipes only follow measured "feel" targets: pitch, timing, decay and level.

Run from the project root:
    uv run -q --with numpy python scripts/sounds/generate_flow_sounds.py

Output: FreeFlow/Resources/Sounds/flow_<pack>_<slot>.wav (48 kHz, 16-bit PCM).
Deterministic: every file uses a fixed seed derived from its name.
"""

import math
import os
import sys
import wave
import zlib

import numpy as np

SR = 48000
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(ROOT, "FreeFlow", "Resources", "Sounds")

# ---------------------------------------------------------------------------
# Notes (equal temperament, A4 = 440)
# ---------------------------------------------------------------------------


def et(f):
    """Round a frequency to the nearest equal-tempered note."""
    n = round(12 * math.log2(f / 440.0))
    return 440.0 * 2 ** (n / 12)


E2, A2, B2, C2, GS1 = et(82.41), et(110), et(123.47), et(65.41), et(51.91)
AS2, C3, E3, F3, GS3, A3 = et(116.54), et(130.81), et(164.81), et(174.61), et(207.65), et(220)
C4, CS4, D4, DS4, E4, FS4, G4, GS4, A4, B4 = (
    et(261.63), et(277.18), et(293.66), et(311.13), et(329.63),
    et(369.99), et(392.0), et(415.3), et(440.0), et(493.88),
)
C5, CS5, D5, DS5, E5, G5 = et(523.25), et(554.37), et(587.33), et(622.25), et(659.26), et(783.99)
C6, DS6, E6 = et(1046.5), et(1244.5), et(1318.5)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def ms(t):
    return int(round(t * SR / 1000.0))


def db2a(db):
    return 10 ** (db / 20.0)


def a2db(a):
    return 20 * math.log10(max(a, 1e-12))


def peak(x):
    return float(np.max(np.abs(x))) if x.size else 0.0


class Ctx:
    """Per-file random source (seeded from the file name)."""

    rng = np.random.default_rng(0)

    @classmethod
    def seed(cls, name):
        cls.rng = np.random.default_rng(zlib.crc32(name.encode()))


def env(n, attack=1.0, taus=(50,)):
    """Raised-cosine attack, then exponential decay a(t) = exp(-t/tau).

    taus: list of stages; each stage is tau_ms or (tau_ms, until_db). A stage with
    until_db switches to the next tau once the level reaches that many dB.
    """
    t = np.arange(n) / SR * 1000.0
    a = np.ones(n)
    att = max(float(attack), 0.05)
    ia = t < att
    a[ia] = 0.5 - 0.5 * np.cos(np.pi * t[ia] / att)
    td = t - att
    level = np.zeros(n)
    start_t, start_db = 0.0, 0.0
    stages = [s if isinstance(s, tuple) else (s, None) for s in taus]
    for i, (tau, until) in enumerate(stages):
        slope = 8.685889638 / tau  # dB per ms
        if until is None or i == len(stages) - 1:
            m = td >= start_t
            level[m] = start_db - slope * (td[m] - start_t)
            break
        dt = (start_db - until) / slope
        m = (td >= start_t) & (td < start_t + dt)
        level[m] = start_db - slope * (td[m] - start_t)
        start_t, start_db = start_t + dt, until
    dec = np.where(td > 0, 10 ** (level / 20.0), 1.0)
    return a * dec


def osc(n, f, glide=None, vib=None, phase=None):
    """Sine oscillator. glide=(f_from, f_to, ms) relative to f; vib=(hz, depth, phase)."""
    t = np.arange(n) / SR
    freq = np.full(n, float(f))
    if glide:
        f0, f1, gms = glide
        g = np.clip(t * 1000.0 / gms, 0, 1)
        freq = f * (f0 / f) * (f1 / f0) ** g
    if vib:
        hz, depth, vph = vib
        freq = freq * (1 + depth * np.sin(2 * np.pi * hz * t + vph))
    if phase is None:
        phase = Ctx.rng.uniform(0, 2 * np.pi)
    return np.sin(2 * np.pi * np.cumsum(freq) / SR + phase)


def tone(f, dur, attack=2.0, taus=(50,), partials=(), glide=None, vib=None, detune=0.5):
    """A note: fundamental plus our own partial mix. partials=[(ratio, dB, tau)]."""
    n = ms(dur)
    f = f + (Ctx.rng.uniform(-detune, detune) if detune else 0.0)
    x = osc(n, f, glide=glide, vib=vib) * env(n, attack, taus)
    for ratio, db, tau in partials:
        g = None
        if glide:
            g = (glide[0] * ratio, glide[1] * ratio, glide[2])
        x = x + db2a(db) * osc(n, f * ratio, glide=g, vib=vib) * env(n, attack, (tau,))
    return x


def biquad(x, b, a):
    b0, b1, b2 = b
    _, a1, a2 = a
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(len(x)):
        xi = x[i]
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, xi, y1, yi
        y[i] = yi
    return y


def bandpass(x, fc, q):
    w = 2 * np.pi * fc / SR
    al = np.sin(w) / (2 * q)
    a0 = 1 + al
    return biquad(x, (al / a0, 0.0, -al / a0), (1.0, -2 * np.cos(w) / a0, (1 - al) / a0))


def lowpass(x, hz, q=0.7071):
    if x.ndim == 2:
        return np.stack([lowpass(x[:, c], hz, q) for c in range(x.shape[1])], axis=1)
    w = 2 * np.pi * hz / SR
    al = np.sin(w) / (2 * q)
    c = np.cos(w)
    a0 = 1 + al
    b = ((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0)
    return biquad(x, b, (1.0, -2 * c / a0, (1 - al) / a0))


def noise_burst(n_ms=1.0):
    n = ms(n_ms)
    return Ctx.rng.standard_normal(n) * np.hanning(n + 2)[1:-1]


def click(fc, q=1.7, ring_taus=(1.0,), bump=(5600, -21), dur=40):
    """1 ms band-passed noise + damped sine ring at fc + a quiet high bump. Peak 0 dB."""
    fc = et(fc)
    n = ms(dur)
    nb = np.zeros(n)
    burst = noise_burst(1.0)
    nb[: len(burst)] = burst
    bp = bandpass(nb, fc, q)
    bp = bp / max(peak(bp), 1e-9)
    ring = osc(n, fc) * env(n, 0.15, ring_taus)
    x = bp + ring
    if bump:
        x = x + db2a(bump[1]) * osc(n, et(bump[0])) * env(n, 0.05, (0.4,))
    return x / peak(x)


def knock(modes, levels=None, taus=(8,), attack=1.0, dur=None):
    """Decaying sines with random phase plus a 1 ms noise burst low-passed at 2 kHz. Peak 0 dB."""
    levels = levels or [0] * len(modes)
    taus = list(taus) if len(taus) == len(modes) else [taus[0]] * len(modes)
    dur = dur or max(taus) * 8 + attack + 5
    n = ms(dur)
    x = np.zeros(n)
    for f, lv, tau in zip(modes, levels, taus):
        x += db2a(lv) * osc(n, et(f) + Ctx.rng.uniform(-0.5, 0.5)) * env(n, attack, (tau,))
    nb = np.zeros(n)
    burst = noise_burst(1.0)
    nb[: len(burst)] = burst
    nb = lowpass(nb, 2000)
    x = x / max(peak(x), 1e-9) + db2a(-20) * nb / max(peak(nb), 1e-9)
    return x / peak(x)


def thump(f, tau=30, attack=2, dur=None):
    dur = dur or tau * 7 + attack
    return tone(f, dur, attack=attack, taus=(tau,), partials=[(2, -18, tau * 0.5)])


def mallet(f, dur=400, attack=1.0, tau=60):
    """Marimba-like: f0 + 4f at -20 dB (tau 15) + 10f at -30 dB (tau 5)."""
    return tone(f, dur, attack=attack, taus=(tau,), partials=[(4, -20, 15), (10, -30, 5)])


def room(x, tau_ms, level_db, length_ms=None):
    """Short decaying-noise reverb tail."""
    length_ms = length_ms or tau_ms * 6
    n = ms(length_ms)
    ir = Ctx.rng.standard_normal(n) * np.exp(-np.arange(n) / SR * 1000.0 / tau_ms)
    ir = lowpass(ir, 4000)
    wet = np.convolve(x, ir)
    wet = wet / max(peak(wet), 1e-9) * db2a(level_db) * peak(x)
    out = np.zeros(len(wet))
    out[: len(x)] += x
    return out + wet


def delay(x, d_ms, fb_db, lp_hz):
    """Feedback delay with a one-pole low-pass in the loop."""
    d = ms(d_ms)
    g = db2a(fb_db)
    coef = 1 - math.exp(-2 * math.pi * lp_hz / SR)
    y = np.array(x, dtype=float)
    s = 0.0
    for i in range(d, len(y)):
        s += coef * (y[i - d] - s)
        y[i] += g * s
    return y


def pan_gains(p):
    ang = (p + 1) * np.pi / 4
    return math.cos(ang) * math.sqrt(2), math.sin(ang) * math.sqrt(2)


class Mix:
    def __init__(self, dur, stereo=False):
        self.n = ms(dur)
        self.stereo = stereo
        self.buf = np.zeros((self.n, 2)) if stereo else np.zeros(self.n)

    def add(self, t, snd, db=0.0, pan=0.0, jitter=True):
        if jitter and t > 0:
            t = t + Ctx.rng.uniform(-2, 2)
        i = max(ms(t), 0)
        if i >= self.n:
            return self
        g = db2a(db)
        if self.stereo:
            if snd.ndim == 1:
                gl, gr = pan_gains(pan)
                snd = np.stack([snd * gl, snd * gr], axis=1)
            seg = snd[: self.n - i]
            self.buf[i : i + len(seg)] += g * seg
        else:
            if snd.ndim == 2:
                snd = snd.mean(axis=1)
            seg = snd[: self.n - i]
            self.buf[i : i + len(seg)] += g * seg
        return self


def stereo_pair(fn):
    """Build a stereo sound from two independently seeded (slightly detuned) renders."""
    left = fn()
    right = fn()
    n = max(len(left), len(right))
    out = np.zeros((n, 2))
    out[: len(left), 0] = left
    out[: len(right), 1] = right
    return out


def finish(x, peak_db):
    """Remove DC, 5 ms fade-out, normalize."""
    x = np.array(x, dtype=float)
    chans = [x] if x.ndim == 1 else [x[:, c] for c in range(x.shape[1])]
    out = []
    r = math.exp(-2 * math.pi * 10 / SR)
    for ch in chans:
        y = np.zeros_like(ch)
        px = py = 0.0
        for i in range(len(ch)):
            v = ch[i]
            py = v - px + r * py
            px = v
            y[i] = py
        y = y - y.mean()
        nf = ms(5)
        y[-nf:] *= np.linspace(1, 0, nf)
        out.append(y)
    y = out[0] if x.ndim == 1 else np.stack(out, axis=1)
    return y / peak(y) * db2a(peak_db)


# ---------------------------------------------------------------------------
# Recipes. Each returns (signal, peak_dbfs). Duration targets live in TARGETS.
# ---------------------------------------------------------------------------

RECIPES = {}
TARGETS = {}


def recipe(name, dur):
    def deco(fn):
        RECIPES[name] = fn
        TARGETS[name] = dur
        return fn

    return deco


# ---------------- Default pack ----------------


@recipe("default_start", 180)
def default_start():
    m = Mix(180)
    m.add(0, tone(D4, 180, attack=2, taus=(6,)), -22)
    m.add(22, tone(A4, 158, attack=5, taus=((4, -22), 35), glide=(444, 438, 60),
                   partials=[(2, -40, 20)]), 0)
    m.add(30, tone(D4, 150, attack=5, taus=(40,)), -32)
    return m.buf, -16.0


def _flutter(x, f, depth):
    """Fast amplitude flutter: gives the woody, slightly rough body."""
    t = np.arange(len(x)) / SR
    return x * (1 - depth * (0.5 - 0.5 * np.cos(2 * np.pi * f * t)))


@recipe("default_stop", 200)
def default_stop():
    # Fitted to measurements of the reference by a parameter search: band energy
    # (mostly 200-400 Hz) and the 5 ms envelope over the first 200 ms.
    m = Mix(200)
    m.add(0, tone(A4, 200, attack=3, taus=(10,)), -20)
    m.add(38, _flutter(tone(D4, 162, attack=3, taus=((4, -24), 30), glide=(282, D4, 18)), 30, 0.8), 0)
    m.add(38, tone(CS4, 162, attack=3, taus=(30,)), -15)
    m.add(38, tone(196.0, 162, attack=3, taus=((6, -24), 30)), -18)
    return m.buf, -16.6


@recipe("default_lock", 170)
def default_lock():
    # Fitted to measurements of the reference double knock: band energy within ~1 dB.
    m = Mix(170)
    k1 = knock([165, 200, 260, 315, 395, 490, 620, 1300, 2080],
               levels=[-12, -10, 0, -3, 1, -4, -6, -6, -10],
               taus=[9, 8, 7, 6, 5, 5, 4, 3, 2], attack=1.5, dur=80)
    k2 = knock([128, 165, 210, 520, 700, 1040],
               levels=[-11, -8, -2, -2, -17, -8], taus=[12, 11, 10, 8, 10, 3], attack=4, dur=100)
    m.add(0, k1, 0)
    m.add(0, click(2200, q=1.4, ring_taus=(0.8,), dur=20), -14)
    m.add(62, k2, -6)
    m.add(62, click(1760, q=1.4, ring_taus=(0.8,), dur=20), -17)
    return m.buf, -21.2


def _mallet_note(f, attack):
    return tone(f, 600, attack=attack, taus=(50,), partials=[(2.76, -15, 25)])


@recipe("default_paste", 620)
def default_paste():
    m = Mix(620)
    m.add(0, _mallet_note(C4, 16), 0)
    m.add(95, _mallet_note(G4, 8), -5)
    m.add(285, _mallet_note(C5, 8), -7)
    x = delay(m.buf, 185, -12, 1500)
    return lowpass(x, 2000), -20.0


def _bell(f0, partials, tau, dur, vib_phase):
    return tone(f0, dur, attack=9, taus=(tau,), partials=partials, detune=0,
                vib=(0.8, 0.003, vib_phase))


@recipe("default_achievement", 1400)
def default_achievement():
    parts = [(2, -19, 400), (3, -27, 120), (4, -36, 80)]
    out = np.zeros((ms(1400), 2))
    for c, (df, ph) in enumerate([(-0.5, 0.0), (0.5, np.pi)]):
        dry = tone(GS4 + df, 1400, attack=9, taus=(180,), partials=parts, detune=0)
        wet = _bell(GS4 + df, parts, 180, 1400, ph)
        out[:, c] = dry + db2a(-9) * wet
    return out, -6.0


@recipe("v1_achievement", 1400)
def v1_achievement():
    parts = [(2, -14, 300), (3, -24, 150)]
    out = np.zeros((ms(1400), 2))
    for c, (df, ph) in enumerate([(-0.5, 0.0), (0.5, np.pi)]):
        dry = tone(C5 + df, 1400, attack=6, taus=(220,), partials=parts, detune=0)
        wet = _bell(C5 + df, parts, 220, 1400, ph)
        out[:, c] = dry + db2a(-9) * wet
    return out, -6.0


@recipe("default_notify_success", 900)
def default_notify_success():
    m = Mix(900, stereo=True)
    m.add(0, tone(G5, 900, attack=1, taus=((60, -6), 150)), 0, pan=0)
    m.add(0, tone(C6, 900, attack=1, taus=(150,)), -8, pan=0.6)
    m.add(0, tone(E6, 900, attack=1, taus=(180,)), -1, pan=-0.6)
    return m.buf, -13.0


@recipe("default_notify_error", 400)
def default_notify_error():
    m = Mix(400, stereo=True)
    m.add(0, tone(A4, 400, attack=2, taus=(50,)), 0, pan=-0.25)
    m.add(0, tone(E5, 400, attack=2, taus=(50,)), 0, pan=0.25)
    m.add(0, tone(E4, 400, attack=2, taus=(80,)), -30)
    return m.buf, -12.0


@recipe("default_notify_alert", 900)
def default_notify_alert():
    m = Mix(900)
    m.add(0, tone(C4, 900, attack=12, taus=(60,)), -6)
    m.add(60, tone(G4, 840, attack=8, taus=((70, -20), 200), vib=(6, 0.005, 0.0)), 0)
    return m.buf, -6.0


# ---------------- notifv2 ----------------


@recipe("notifv2_notify_success", 2000)
def notifv2_success():
    taus = ((86.9, -6), 320)

    def chord(df):
        m = Mix(2000)
        for f, db in [(C4, -5), (G4, 0), (C5, -10)]:
            m.add(0, tone(f + df, 2000, attack=14, taus=taus, detune=0), db)
        for f, db in [(C4, -5), (G4, 0), (C5, -10)]:
            m.add(585, tone(f + df, 1415, attack=14, taus=(120,), detune=0), db - 25)
        return m.buf

    mid = chord(0.0)
    side = chord(0.7)
    out = np.stack([mid + 0.5 * side, mid - 0.5 * side], axis=1)
    return out, -17.0


@recipe("notifv2_notify_error", 700)
def notifv2_error():
    m = Mix(700)
    for t, g in zip([0, 35, 85, 125, 175, 210], [0, 0, -1, -7, -16, -24]):
        pulse = (tone(A3, 600, attack=4, taus=(45,))
                 + tone(E3, 600, attack=4, taus=(45,))
                 + db2a(-18) * tone(E2, 600, attack=4, taus=(70,)))
        m.add(t, pulse, g)
    swell = env(m.n, 50, (100000,))
    return m.buf * swell, -3.0


@recipe("notifv2_notify_alert", 900)
def notifv2_alert():
    m = Mix(900)
    m.add(0, tone(G4, 900, attack=16, taus=(136,), partials=[(2, -24, 60)]), 0)
    m.add(135, tone(C5, 765, attack=6, taus=((100, -17), 250), partials=[(2, -24, 60)]), -3)
    return m.buf, -13.0


# ---------------- Click packs ----------------

CLICK_PEAK = -3.0


def pre_tone():
    return (tone(B4, 50, attack=10, taus=(30,)) + tone(G4, 50, attack=10, taus=(30,))) * np.linspace(1, 0.6, ms(50))


def v1_start_sound():
    c = click(1000, ring_taus=(1.1,), dur=20)
    return room(c, 17.8, -20, 100)


@recipe("v1_start", 120)
def v1_start():
    m = Mix(120)
    m.add(0, v1_start_sound(), 0)
    return m.buf, CLICK_PEAK


@recipe("v1_stop", 450)
def v1_stop():
    m = Mix(450)
    m.add(0, click(800, ring_taus=(1.2,)), 0)
    tail = tone(A4, 400, attack=3, taus=(49,)) + tone(D4, 400, attack=3, taus=(49,))
    m.add(55, tail / peak(tail), -12)
    return m.buf, CLICK_PEAK


@recipe("v1_lock", 700)
def v1_lock():
    m = Mix(700)
    m.add(0, click(1000, ring_taus=(1.1,)), 0)
    m.add(75, click(1100, ring_taus=(1.1,)), -7)
    m.add(150, tone(880, 550, attack=2, taus=(78,)), -26)
    return m.buf, CLICK_PEAK


def _v2_start_channel(tail_scale=1.0):
    m = Mix(300)
    m.add(0, thump(F3, tau=36, attack=2), -9)
    tc = click(G5, q=2.5, ring_taus=(4,), dur=60) + 0.6 * tone(G5, 60, attack=0.5, taus=(8,))
    tc = tc / peak(tc)
    m.add(35, tc, 0)
    m.add(80, tone(G4, 200, attack=1, taus=(30 * tail_scale,)), -7)
    m.add(135, tc, -22)
    m.add(185, tc, -33)
    return m.buf


@recipe("v2_start", 300)
def v2_start():
    return stereo_pair(_v2_start_channel), CLICK_PEAK


@recipe("v2_stop", 300)
def v2_stop():
    m = Mix(300)
    m.add(0, tone(G4, 200, attack=10, taus=(40,)), 0)
    m.add(100, thump(A2, tau=30), -17)
    m.add(160, thump(B2, tau=30), -27)
    return m.buf, CLICK_PEAK


@recipe("v2_lock", 260)
def v2_lock():
    return stereo_pair(lambda: _v2_start_channel(0.7)[: ms(260)]), CLICK_PEAK


@recipe("v3_stop", 300)
def v3_stop():
    m = Mix(300)
    m.add(0, click(1400, ring_taus=(0.8,)) + click(500, ring_taus=(1.5,)), 0)
    m.add(45, tone(C5, 250, attack=2, taus=(40,)), -13)
    m.add(95, tone(A4, 200, attack=2, taus=(50,)), -24)
    return m.buf, CLICK_PEAK


@recipe("v3_lock", 650)
def v3_lock():
    m = Mix(650)
    m.add(0, click(1000, ring_taus=(1.1,)), 0)
    m.add(70, click(1100, ring_taus=(1.1,)), -8)
    m.add(140, tone(880, 500, attack=2, taus=(78,)), -27)
    return m.buf, CLICK_PEAK


@recipe("v4_start", 250)
def v4_start():
    m = Mix(250)
    m.add(0, tone(B4, 250, attack=22, taus=(30,), partials=[(2, -20, 15)]), -6)
    m.add(80, tone(D5, 170, attack=2, taus=(11,), partials=[(2, -20, 8)]), 0)
    return m.buf, -20.0


@recipe("v4_stop", 300)
def v4_stop():
    m = Mix(300)
    m.add(0, tone(C4, 300, attack=40, taus=(40,)) + tone(GS3, 300, attack=40, taus=(40,)), -6)
    m.add(40, tone(CS4, 260, attack=3, taus=(30,)), -4)
    m.add(75, tone(CS5, 225, attack=2, taus=(30,)), 0)
    m.add(110, tone(C4, 190, attack=3, taus=(50,)), -4)
    return m.buf, -20.0


@recipe("v4_lock", 350)
def v4_lock():
    m = Mix(350)
    m.add(0, tone(B4, 350, attack=2, taus=(25,)) + tone(E5, 350, attack=2, taus=(25,)), 0)
    m.add(80, tone(D5, 270, attack=2, taus=(25,)), -7)
    cl = tone(C5, 200, attack=10, taus=(60,)) + tone(CS5, 200, attack=10, taus=(60,)) + tone(D5, 200, attack=10, taus=(60,))
    m.add(150, cl / peak(cl), -25)
    return m.buf, -20.0


def _v5_start(m):
    m.add(0, tone(C4, 400, attack=32, taus=(40,), partials=[(2, -18, 20)]), -8)
    m.add(80, tone(E4, 320, attack=0.5, taus=(50,), partials=[(2, -18, 25)]), 0)


@recipe("v5_start", 400)
def v5_start():
    m = Mix(400)
    _v5_start(m)
    return m.buf, -12.0


@recipe("v5_stop", 350)
def v5_stop():
    m = Mix(350)
    m.add(0, tone(E4, 350, attack=74, taus=(30,), partials=[(2, -18, 20)]), 0)
    m.add(85, tone(C4, 265, attack=1, taus=(50,), partials=[(2, -18, 25)]), 0)
    return m.buf, -13.0


@recipe("v5_lock", 500)
def v5_lock():
    m = Mix(500)
    _v5_start(m)
    m.add(225, tone(E6, 275, attack=6, taus=(60,)), -25)
    return m.buf, -11.0


@recipe("v6_start", 600)
def v6_start():
    m = Mix(600, stereo=True)
    m.add(0, mallet(C4, tau=120), 0, pan=-0.3)
    m.add(0, tone(AS2, 600, attack=2, taus=(90,)), -6)
    m.add(0, tone(E2, 600, attack=2, taus=(90,)), -9)
    m.add(75, mallet(E4, tau=110), 0, pan=0.3)
    m.add(120, mallet(C4, tau=110) + mallet(E4, tau=110), -3, pan=0)
    m.add(160, mallet(E4, tau=110), -15, pan=0.3)
    return m.buf, CLICK_PEAK


@recipe("v6_stop", 500)
def v6_stop():
    m = Mix(500, stereo=True)
    m.add(0, mallet(E4, tau=90), -2, pan=0.25)
    m.add(80, mallet(C3, dur=420, tau=100) + 0.5 * tone(C3 / 2, 420, attack=2, taus=(80,)), 0, pan=-0.1)
    return m.buf, CLICK_PEAK


@recipe("v6_lock", 550)
def v6_lock():
    m = Mix(550, stereo=True)
    times = [0, 70, 105, 150, 190, 260, 295, 340, 395]
    gains = np.linspace(-4, -27, len(times))
    for i, (t, g) in enumerate(zip(times, gains)):
        f, p = (C4, -0.3) if i % 2 == 0 else (E4, 0.3)
        m.add(t, mallet(f, dur=300, tau=70), g, pan=p)
    return m.buf, CLICK_PEAK


def v7_stop_events(m, lead=0.0, subs=False):
    m.add(lead, click(2000, ring_taus=(0.5,), dur=20), -12)
    if subs:
        sub = tone(GS1, 200, attack=2, taus=(40,)) + tone(A2, 200, attack=2, taus=(35,))
        m.add(lead, sub / peak(sub), -6)
    m.add(lead + 55, knock([B4, G4], taus=(10,), attack=1, dur=80), -9)
    main = knock([G5, E4], levels=[0, -3], taus=(3.3,), attack=0.5, dur=60)
    main = main + 0.5 * bandpass(click(700, ring_taus=(2,), dur=60), 710, 1.2)
    m.add(lead + 90, main / peak(main), 0)


@recipe("v7_start", 150)
def v7_start():
    m = Mix(150)
    m.add(0, pre_tone(), -40)
    m.add(50, click(1000, ring_taus=(1.2,), dur=80), 0)
    return m.buf, CLICK_PEAK


@recipe("v7_stop", 168)
def v7_stop():
    m = Mix(168)
    v7_stop_events(m)
    return m.buf, CLICK_PEAK


def v7_lock_events(m, lead):
    m.add(lead, click(1000, ring_taus=(1.2,), dur=80), 0)
    m.add(lead + 90, click(1000, ring_taus=(1.2,), dur=80), -3)
    m.add(lead + 180, click(1000, ring_taus=(1.0,), dur=60), -18)


@recipe("v7_lock", 320)
def v7_lock():
    m = Mix(320)
    m.add(0, pre_tone(), -40)
    v7_lock_events(m, 45)
    return m.buf, CLICK_PEAK


@recipe("v7_2_start", 250)
def v7_2_start():
    m = Mix(250)
    m.add(0, click(1000, ring_taus=(1.2,), dur=80), 0)
    m.add(165, click(1000, ring_taus=(1.2,), dur=80), 0)
    return m.buf, CLICK_PEAK


@recipe("v7_2_stop", 243)
def v7_2_stop():
    m = Mix(243)
    v7_stop_events(m, lead=75)
    return m.buf, CLICK_PEAK


@recipe("v7_2_lock", 420)
def v7_2_lock():
    m = Mix(420)
    for t, g in [(0, 0), (165, 0), (260, -3), (350, -20)]:
        m.add(t, click(1000, ring_taus=(1.2,), dur=60), g)
    return m.buf, CLICK_PEAK


def tonal_knock(fs, tau=41, dur=350):
    k = knock(fs, taus=(tau,), attack=1.5, dur=dur)
    return k


@recipe("v8_start", 400)
def v8_start():
    m = Mix(400)
    m.add(0, pre_tone(), -40)
    m.add(50, tonal_knock([B4, G4]), 0)
    return m.buf, CLICK_PEAK


def _v8_stop(final):
    m = Mix(300)
    m.add(0, click(2400, ring_taus=(0.5,), dur=20), -12)
    m.add(35, thump(A3, tau=25), -14)
    m.add(85, knock(final, taus=(30,), attack=1, dur=215), 0)
    return m.buf


@recipe("v8_stop", 300)
def v8_stop():
    return _v8_stop([FS4, G4]), CLICK_PEAK


@recipe("v8_lock", 400)
def v8_lock():
    m = Mix(400)
    m.add(80, click(1000, ring_taus=(1.2,), dur=60), 0)
    m.add(135, tone(B4, 200, attack=2, taus=(30,)), -18)
    m.add(170, click(1000, ring_taus=(1.2,), dur=60), -2)
    m.add(225, tone(B4, 175, attack=2, taus=(30,)), -18)
    return m.buf, CLICK_PEAK


def click_thump():
    x = click(1000, ring_taus=(1.2,), dur=200) + 0.8 * thump(C2, tau=28, attack=1.5, dur=200)
    return x / peak(x)


@recipe("v8_2_start", 450)
def v8_2_start():
    m = Mix(450)
    m.add(0, click_thump(), 0)
    m.add(165, tonal_knock([B4, G4], dur=285), 0)
    return m.buf, CLICK_PEAK


@recipe("v8_2_stop", 300)
def v8_2_stop():
    return _v8_stop([G4]), CLICK_PEAK


@recipe("v8_2_lock", 500)
def v8_2_lock():
    m = Mix(500)
    m.add(0, click_thump(), 0)
    for t, g in [(165, 0), (255, -3), (350, -19)]:
        m.add(t, knock([G4], taus=(25,), attack=1, dur=150), g)
    return m.buf, CLICK_PEAK


def woody():
    return knock([370, 392, 415, 440], levels=[-3, 0, -4, -6], taus=(14,), attack=1, dur=120)


def cs5_hit():
    x = tone(CS5, 200, attack=1, taus=(30,)) + 0.7 * click(1000, ring_taus=(1.0,), dur=200)
    return x / peak(x)


@recipe("v9_start", 350)
def v9_start():
    m = Mix(350)
    m.add(0, woody(), 0)
    m.add(125, cs5_hit(), 0)
    return m.buf, CLICK_PEAK


@recipe("v9_stop", 300)
def v9_stop():
    m = Mix(300)
    m.add(30, click(2000, ring_taus=(0.5,), dur=20), -12)
    m.add(85, click(2000, ring_taus=(0.5,), dur=20), -12)
    m.add(120, thump(CS4, tau=35), 0)
    return m.buf, CLICK_PEAK


@recipe("v9_lock", 450)
def v9_lock():
    m = Mix(450)
    m.add(0, woody(), 0)
    for t, g in [(125, 0), (215, -4), (310, -20)]:
        m.add(t, cs5_hit(), g)
    return m.buf, CLICK_PEAK


@recipe("v10_start", 300)
def v10_start():
    m = Mix(300)
    for f, db in [(E4, 0), (DS4, -4), (CS4, -6)]:
        m.add(0, tone(f, 300, attack=108, taus=(35,)), db)
    return m.buf, -18.0


@recipe("v10_stop", 260)
def v10_stop():
    m = Mix(260)
    m.add(0, tone(E4, 260, attack=28, taus=(62,)), 0)
    m.add(0, tone(C4, 260, attack=28, taus=(62,)), -3)
    return m.buf, -18.0


@recipe("v10_lock", 400)
def v10_lock():
    m = Mix(400)
    m.add(0, tone(E4, 400, attack=60, taus=(40,)), 0)
    m.add(180, tone(E4, 220, attack=2, taus=(30,)), -11)
    m.add(270, tone(E4, 130, attack=2, taus=(30,)), -25)
    return m.buf, -18.0


@recipe("v11_start", 93)
def v11_start():
    m = Mix(93)
    m.add(0, click(C6, ring_taus=((11.3, -20), 4.3), dur=93), 0)
    return m.buf, CLICK_PEAK


@recipe("v11_2_start", 60)
def v11_2_start():
    m = Mix(60)
    x = click(1120, ring_taus=(4,), dur=60) + db2a(-10) * tone(GS4, 60, attack=1, taus=(15,))
    m.add(0, x, 0)
    return m.buf, -3.6


@recipe("v11_3_start", 66)
def v11_3_start():
    m = Mix(66)
    m.add(0, click(1000, ring_taus=(5,), dur=66), 0)
    return m.buf, -2.6


@recipe("v11_4_start", 129)
def v11_4_start():
    m = Mix(129)
    x = tone(C5, 129, attack=1, taus=(23,)) + click(1000, ring_taus=(2,), dur=129)
    m.add(0, x, 0)
    return m.buf, CLICK_PEAK


@recipe("v12_start", 112)
def v12_start():
    m = Mix(112)
    m.add(0, click(1050, ring_taus=((3, -20), 20), dur=112), 0)
    return m.buf, CLICK_PEAK


@recipe("v12_stop", 279)
def v12_stop():
    m = Mix(279)
    v7_stop_events(m, subs=True)
    return m.buf, CLICK_PEAK


@recipe("v12_lock", 292)
def v12_lock():
    m = Mix(292)
    v7_lock_events(m, 0)
    return m.buf, CLICK_PEAK


@recipe("v12_paste", 145)
def v12_paste():
    m = Mix(145)
    m.add(0, click(2000, ring_taus=(2.5,), dur=60), 0)
    m.add(50, click(2000, ring_taus=(3.5,), dur=60), -2)
    return m.buf, -5.8


@recipe("t1_start", 1060)
def t1_start():
    m = Mix(1060, stereo=True)
    notes = [C5, DS5, CS5, DS6, E6]
    times = np.sort(Ctx.rng.uniform(0, 820, 15))
    times[0] = 0
    idx = 0
    for t in times:
        idx = (idx + int(Ctx.rng.integers(-1, 3))) % len(notes)
        f = notes[idx]
        att = float(Ctx.rng.uniform(20, 60))
        g = float(Ctx.rng.uniform(-12, 0))
        p = float(Ctx.rng.uniform(-0.6, 0.6))
        snd = tone(f, 1060 - t, attack=att, taus=(80,), partials=[(2, -22, 30)])
        m.add(float(t), snd, g, pan=p, jitter=False)
    return m.buf, -3.0


# ---------------------------------------------------------------------------
# Output and verification
# ---------------------------------------------------------------------------


def write_wav(path, x):
    data = np.round(x * 32767.0)
    assert np.max(np.abs(data)) <= 32767, f"clipping in {path}"
    data = data.astype("<i2")
    ch = 1 if x.ndim == 1 else x.shape[1]
    with wave.open(path, "wb") as w:
        w.setnchannels(ch)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


def stats(x):
    mono = x if x.ndim == 1 else x.mean(axis=1)
    pk = a2db(peak(x))
    rms = a2db(float(np.sqrt(np.mean(mono ** 2))))
    spec = np.abs(np.fft.rfft(mono))
    freqs = np.fft.rfftfreq(len(mono), 1 / SR)
    centroid = float(np.sum(freqs * spec) / max(np.sum(spec), 1e-12))
    return len(mono) / SR * 1000.0, pk, rms, centroid


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    only = set(sys.argv[1:])
    print(f"{'file':34} {'ch':>2} {'ms':>6} {'target':>6} {'peak':>7} {'rms':>7} {'centroid':>9}")
    failures = []
    for name, fn in RECIPES.items():
        if only and name not in only:
            continue
        Ctx.seed(name)
        x, pk_db = fn()
        target = TARGETS[name]
        n = ms(target)
        if len(x) < n:
            pad = np.zeros((n - len(x),) + x.shape[1:])
            x = np.concatenate([x, pad])
        x = finish(x[:n], pk_db)
        path = os.path.join(OUT_DIR, f"flow_{name}.wav")
        write_wav(path, x)
        dur, pk, rms, cen = stats(x)
        ch = 1 if x.ndim == 1 else 2
        print(f"flow_{name + '.wav':29} {ch:>2} {dur:6.0f} {target:6.0f} {pk:7.1f} {rms:7.1f} {cen:9.0f}")
        if abs(dur - target) > 0.15 * target:
            failures.append(f"{name}: duration {dur:.0f} vs {target}")
        if pk > -0.01:
            failures.append(f"{name}: clipping")
        if name in ("default_start", "default_stop") and not (-17.0 <= pk <= -15.0):
            failures.append(f"{name}: peak {pk:.1f} outside -17..-15")
        if abs(float(np.mean(x))) > 1e-4:
            failures.append(f"{name}: DC offset")
        if os.path.getsize(path) > 400 * 1024:
            failures.append(f"{name}: file larger than 400 KB")
    assert not failures, "\n".join(failures)
    print("ok")


if __name__ == "__main__":
    main()
