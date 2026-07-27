#!/usr/bin/env python
# Forced alignment: takes whisper's word list + the audio and returns the SAME
# words with precise, measured start/end times (wav2vec2 CTC forced alignment).
# This is the "measurement" whisper can't do on its own - it finds each word's
# real position in the audio at the phoneme level (YouTube-style).
#
# Usage: python align.py --audio in.wav --words words.srt --out aligned.srt
#
# --words / --out are word-level .srt files (one word per cue). Only the WORD
# TEXT and order from --words are used; the times are recomputed from the audio.
import sys, os, re, argparse, warnings
warnings.filterwarnings("ignore")

def read_word_srt(path):
    txt = open(path, encoding="utf-8").read().replace("\r\n", "\n").replace("\r", "\n")
    words = []
    for b in re.split(r"\n[ \t]*\n+", txt.strip()):
        lines = b.split("\n")
        ti = next((i for i, l in enumerate(lines)
                   if re.search(r"\d+:\d\d:\d\d[,.]\d+\s*-->", l)), None)
        if ti is None:
            continue
        w = " ".join(lines[ti + 1:]).strip()
        if w:
            words.append(w)
    return words

def fmt_ts(sec):
    if sec < 0:
        sec = 0.0
    ms = int(round(sec * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio", required=True)
    ap.add_argument("--words", required=True)
    ap.add_argument("--out",   required=True)
    a = ap.parse_args()

    words = read_word_srt(a.words)
    if not words:
        print("align: no words in input", file=sys.stderr)
        sys.exit(2)

    import wave
    import numpy as np
    import torch, torchaudio
    from torchaudio.functional import forced_align, merge_tokens
    torch.set_num_threads(max(1, (os.cpu_count() or 2)))

    def load_wav(path, target_sr):
        # Read a PCM WAV with the stdlib (no torchaudio audio backend needed on
        # Windows). Returns a mono float32 tensor [1, samples] at target_sr.
        with wave.open(path, "rb") as w:
            n_ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
            raw = w.readframes(n)
        if sw == 2:
            data = np.frombuffer(raw, dtype="<i2").astype("float32") / 32768.0
        elif sw == 1:
            data = (np.frombuffer(raw, dtype=np.uint8).astype("float32") - 128.0) / 128.0
        elif sw == 4:
            data = np.frombuffer(raw, dtype="<i4").astype("float32") / 2147483648.0
        else:
            raise RuntimeError(f"unsupported WAV sample width: {sw}")
        if n_ch > 1:
            data = data.reshape(-1, n_ch).mean(axis=1)
        t = torch.from_numpy(data.copy()).unsqueeze(0)
        if sr != target_sr:
            t = torchaudio.functional.resample(t, sr, target_sr)
        return t

    bundle = torchaudio.pipelines.WAV2VEC2_ASR_BASE_960H
    model = bundle.get_model()
    model.eval()
    labels = bundle.get_labels()
    DICT = {c: i for i, c in enumerate(labels)}   # '-'=0 (blank), '|'=word sep, then A-Z and '
    SR = bundle.sample_rate                        # 16000

    wav = load_wav(a.audio, SR)

    with torch.inference_mode():
        emissions, _ = model(wav)
        emissions = torch.log_softmax(emissions, dim=-1)
    emission = emissions.cpu()

    # normalise each word to the model's alphabet (upper-case A-Z and apostrophe);
    # drop punctuation/digits. Words with nothing left get interpolated later.
    norm = ["".join(ch for ch in w.upper() if ch in DICT and ch not in ("-", "|"))
            for w in words]
    align_idx = [i for i, s in enumerate(norm) if s]
    flat, lengths = [], []
    for i in align_idx:
        toks = [DICT[c] for c in norm[i]]
        flat.extend(toks)
        lengths.append(len(toks))

    times = {}
    if flat:
        targets = torch.tensor([flat], dtype=torch.int32)
        aligned, scores = forced_align(emission, targets, blank=0)
        spans = merge_tokens(aligned[0], scores[0].exp())
        ratio = wav.size(1) / emission.size(1) / SR   # seconds per emission frame
        p = 0
        for k, i in enumerate(align_idx):
            L = lengths[k]
            sp = spans[p:p + L]
            p += L
            if sp:
                times[i] = (sp[0].start * ratio, sp[-1].end * ratio)

    # assemble every word's time; interpolate any that couldn't be aligned
    results = []
    for i in range(len(words)):
        if i in times:
            results.append(list(times[i]))
        else:
            prev_end = results[-1][1] if results else 0.0
            nxt = next((times[j][0] for j in range(i + 1, len(words)) if j in times), None)
            st = prev_end
            en = nxt if nxt is not None else prev_end + 0.1
            if en <= st:
                en = st + 0.1
            results.append([st, en])

    out = []
    for i, (st, en) in enumerate(results):
        if en <= st:
            en = st + 0.02
        out.append(str(i + 1))
        out.append(f"{fmt_ts(st)} --> {fmt_ts(en)}")
        out.append(words[i])
        out.append("")
    open(a.out, "w", encoding="utf-8", newline="").write("\r\n".join(out).rstrip() + "\r\n")
    print(f"align: {len(words)} words aligned ({len(times)} measured, {len(words)-len(times)} interpolated)",
          file=sys.stderr)

if __name__ == "__main__":
    main()
