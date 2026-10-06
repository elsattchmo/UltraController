"""Weapon sound preparation: slices the source recordings in assets/audio/source/ into single
one-shots (onset detection), trims / normalises / fades them, and renders a "far" version of every
firing sound (low-passed, a reverb tail, quieter) for distant listeners.

    python tools/audio/prepare_sfx.py

Writes assets/audio/weapons/<name>_<k>.wav (16-bit mono). numpy only (no scipy): the filters are
plain biquads / Schroeder reverb loops - fine for clips this short.
"""
import os
import struct
import wave

import numpy as np

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..'))
SRC = os.path.join(ROOT, 'assets', 'audio', 'source')
OUT = os.path.join(ROOT, 'assets', 'audio', 'weapons')


def read_wav(path):
    """Mono float32 [-1, 1] and the sample rate (PCM 8/16/24/32 and IEEE float)."""
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:4] == b'RIFF' and data[8:12] == b'WAVE', path
    pos = 12
    fmt = None
    pcm = None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack('<I', data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b'fmt ':
            tag, ch, sr, _, _, bits = struct.unpack('<HHIIHH', body[:16])
            if tag == 0xFFFE and len(body) >= 26:          # WAVE_FORMAT_EXTENSIBLE: the subformat
                tag = struct.unpack('<H', body[24:26])[0]
            fmt = (tag, ch, sr, bits)
        elif cid == b'data':
            pcm = body
        pos += 8 + size + (size & 1)
    tag, ch, sr, bits = fmt
    if tag == 3:
        a = np.frombuffer(pcm, dtype=np.float32 if bits == 32 else np.float64).astype(np.float32)
    elif bits == 16:
        a = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
    elif bits == 24:
        b = np.frombuffer(pcm, dtype=np.uint8).reshape(-1, 3)
        v = (b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8) | (b[:, 2].astype(np.int32) << 16))
        v = np.where(v & 0x800000, v - 0x1000000, v)
        a = v.astype(np.float32) / 8388608.0
    elif bits == 32:
        a = np.frombuffer(pcm, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        a = (np.frombuffer(pcm, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    a = a[: len(a) // ch * ch].reshape(-1, ch).mean(axis=1)
    return a, sr


def write_wav(path, a, sr):
    a = np.clip(a, -1.0, 1.0)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((a * 32767.0).astype(np.int16).tobytes())


def envelope(a, sr, ms=5):
    win = max(int(sr * ms / 1000), 1)
    n = len(a) // win
    return np.abs(a[: n * win]).reshape(n, win).max(axis=1), win


def slices(a, sr, rel=0.35, gap_ms=150, max_len=1.0, tail_db=-42.0):
    """Start / end samples of each distinct event: an onset past `rel` of the peak (after a
    quieter stretch), until the next onset or the level falls `tail_db` under its own peak."""
    env, win = envelope(a, sr)
    pk = env.max()
    out = []
    i = 1
    last = -10 ** 9
    while i < len(env):
        if env[i] > rel * pk and env[i - 1] < rel * 0.7 * pk and (i - last) * win > gap_ms * sr / 1000:
            start = max(i - 2, 0)
            local = env[i:i + int(0.05 * sr / win) + 1].max()
            j = i + 1
            quiet = 0
            while j < len(env) and (j - start) * win < max_len * sr:
                if env[j] < local * 10 ** (tail_db / 20):
                    quiet += 1
                    if quiet * win > 0.06 * sr:
                        break
                else:
                    quiet = 0
                if env[j] > rel * pk and env[j - 1] < rel * 0.7 * pk and (j - i) * win > gap_ms * sr / 1000:
                    break
                j += 1
            out.append((start * win, j * win))
            last = i
            i = j
        else:
            i += 1
    return out


def finish(x, sr, peak_db=-1.0, fade_in_ms=2, fade_out_ms=25):
    x = x - x.mean()
    m = np.abs(x).max()
    if m > 0:
        x = x / m * 10 ** (peak_db / 20)
    fi = int(sr * fade_in_ms / 1000)
    fo = min(int(sr * fade_out_ms / 1000), len(x) // 2)
    if fi > 0:
        x[:fi] *= np.linspace(0, 1, fi)
    if fo > 0:
        x[-fo:] *= np.linspace(1, 0, fo)
    return x.astype(np.float32)


def biquad_lowpass(x, sr, fc, q=0.707):
    w0 = 2 * np.pi * fc / sr
    alpha = np.sin(w0) / (2 * q)
    cw = np.cos(w0)
    b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
    a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for n in range(len(x)):
        xn = float(x[n])
        yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, xn, y1, yn
        y[n] = yn
    return y


def reverb(x, sr, mix=0.4, decay=0.78):
    """Schroeder: four parallel combs into two all-passes."""
    out = np.zeros(len(x) + int(sr * 1.4), dtype=np.float32)
    src = np.concatenate([x, np.zeros(len(out) - len(x), dtype=np.float32)])
    wet = np.zeros_like(out)
    for ms, g in ((29.7, decay), (37.1, decay * 0.98), (41.1, decay * 0.96), (43.7, decay * 0.94)):
        d = int(sr * ms / 1000)
        buf = np.zeros_like(out)
        for n in range(len(out)):
            buf[n] = src[n] + (g * buf[n - d] if n >= d else 0.0)
        wet += buf * 0.25
    for ms, g in ((5.0, 0.7), (1.7, 0.7)):
        d = int(sr * ms / 1000)
        y = np.zeros_like(wet)
        for n in range(len(wet)):
            xd = wet[n - d] if n >= d else 0.0
            yd = y[n - d] if n >= d else 0.0
            y[n] = -g * wet[n] + xd + g * yd
        wet = y
    out = src * (1 - mix) + wet * mix
    return out


def far(x, sr):
    """A gunshot heard from far off: highs gone, the crack softened, a long tail."""
    y = biquad_lowpass(x, sr, 1100.0)
    y = biquad_lowpass(y, sr, 1100.0)
    y = np.tanh(y * 1.6)                                  # (the transient squashed)
    y = reverb(y, sr, mix=0.55, decay=0.82)
    return finish(y, sr, peak_db=-4.0, fade_out_ms=200)


# name -> (source file, mode, params). mode "slice": every event; "range": [(t0, t1, name)...];
# "whole": the file as one.
JOBS = [
    ('pistol_fire', 'handgun fire.wav', 'slice', dict(rel=0.4, max_len=1.1), True),
    ('rifle_fire', 'automatic fire.wav', 'slice', dict(rel=0.3, max_len=0.6, gap_ms=90), True),
    ('shotgun_fire', 'shotgun/660299__hyperix6__shotgun-fire.wav', 'slice', dict(rel=0.4, max_len=1.6), True),
    ('whiz', 'bullet close.wav', 'slice', dict(rel=0.3, max_len=1.2, gap_ms=400), False),
    ('impact', 'bullet hit.wav', 'slice', dict(rel=0.3, max_len=0.9, gap_ms=300), False),
    ('pistol_reload', 'handgun reload.wav', 'range', [(0.0, 0.36, 'mag_out'), (0.36, 0.88, 'mag_in'), (0.88, 1.51, 'slide')], False),
    ('rifle_reload', 'automatic gun reload.wav', 'range', [(1.95, 3.30, 'mag_out'), (3.36, 5.11, 'mag_in')], False),
    ('shotgun_shell', 'shotgun/107342__thompsonman__shotgun-shell.wav', 'whole', {}, False),
    ('shotgun_pump', 'shotgun/537724__yeet2020202020__realistic-shotgun-cocking-sound.wav', 'whole', {}, False),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, src, mode, params, distant in JOBS:
        a, sr = read_wav(os.path.join(SRC, src))
        outs = []
        if mode == 'slice':
            for k, (s0, s1) in enumerate(slices(a, sr, **params)):
                outs.append(('%s_%d' % (name, k), a[s0:s1]))
        elif mode == 'range':
            for t0, t1, part in params:
                seg = a[int(t0 * sr):int(t1 * sr)]
                # (trim the leading silence)
                env, win = envelope(seg, sr)
                first = int(np.argmax(env > env.max() * 0.08)) * win
                outs.append(('%s_%s' % (name, part), seg[max(first - int(0.005 * sr), 0):]))
        else:
            outs.append((name, a))
        for nm, x in outs:
            x = finish(x.copy(), sr)
            write_wav(os.path.join(OUT, nm + '.wav'), x, sr)
            line = '%-24s %.2f s' % (nm, len(x) / sr)
            if distant:
                write_wav(os.path.join(OUT, nm + '_far.wav'), far(x, sr), sr)
                line += ' + far'
            print(line)


if __name__ == '__main__':
    main()
