# silence-cutter

> Cut silent parts from audio/video files with ffmpeg — preview the plan first, encode only when you say so. Daily Tools #15.

## Why

Recordings of voiceovers, meetings, and screencasts are full of dead air:
pauses while thinking, long gaps between sentences, silence at the start and
end. Manually finding and cutting each gap is tedious. `silence-cutter`
detects silence with ffmpeg's `silencedetect`, shows you exactly what would
be cut (a segment table, JSON, or an EDL file), and only encodes when you
pass `--apply` — so there are no destructive surprises.

The closest alternatives found on GitHub are
[LogicWeave/trimly](https://github.com/LogicWeave/trimly) ("fast, automated
silence removal for voiceover files", audio-only, cuts immediately) and
Drew-Opexcell/auto-video-editor (Python, video-focused). `silence-cutter`
is different: one dependency-free bash file that works fully offline,
handles **both** audio and video, and is **preview-first** — the default
mode changes nothing on disk, which makes it safe to drop into review
pipelines and batch scripts.

## Install

```bash
git clone https://github.com/Kayzenn123/silence-cutter.git
cd silence-cutter
chmod +x silence-cutter.sh
```

Requires: ffmpeg and ffprobe (any recent build). No other dependencies —
works fully offline.

Optional: put it on your PATH:

```bash
ln -s "$PWD/silence-cutter.sh" ~/.local/bin/silence-cutter
```

## Usage

```bash
silence-cutter.sh [options] <input>
```

| Flag | Function | Default |
| --- | --- | --- |
| `--threshold DB` | Silence threshold, e.g. `-35dB` | `-35dB` |
| `--min-duration SEC` | Minimum silence length to cut | `0.8` |
| `--padding SEC` | Keep this much silence around sound | `0.15` |
| `--apply -o FILE` | Encode the trimmed result to FILE | off (dry-run) |
| `--edl FILE` | Write cut ranges as an MPlayer EDL file | off |
| `--json` | Print the plan as JSON instead of a table | off |
| `--version` | Print version and exit | — |
| `--help` | Print help and exit | — |

Exit codes: `0` ok, `1` runtime error (bad media, no audio stream, entirely
silent input), `2` bad usage. Respects `NO_COLOR`; no colors when stdout is
not a TTY. Nothing is written unless you pass `--apply` (or `--edl`).

## Example output

Command:

```bash
./silence-cutter.sh voiceover.wav
```

Output (real, copied from an actual run):

```text
Cut plan for voiceover.wav
duration 11.10 s, 2 silence region(s) -> cut 2.60 s (23.4%), new duration 8.50 s

  #  start      end        duration
   1      0.00      4.05      4.05
   2      5.75      9.05      3.30
   3      9.95     11.10      1.15

dry-run: nothing was encoded. Add --apply -o <file> to cut.
```

Cutting for real, with an EDL sidecar:

```bash
./silence-cutter.sh --threshold -40dB --min-duration 1.0 --padding 0.2 \
  --apply -o voiceover-tight.wav --edl voiceover.edl voiceover.wav
```

```text
wrote EDL: voiceover.edl
Cut plan for voiceover.wav
duration 11.10 s, 2 silence region(s) -> cut 2.40 s (21.6%), new duration 8.70 s

  #  start      end        duration
   1      0.00      4.10      4.10
   2      5.70      9.10      3.40
   3      9.90     11.10      1.20
encoding trimmed output -> voiceover-tight.wav ...
done: voiceover-tight.wav (8.71 s, was 11.10 s)
```

Machine-readable plan for pipelines:

```bash
./silence-cutter.sh --json meeting.mp4
```

```json
{
  "input": "meeting.mp4",
  "duration": 11.100,
  "threshold": "-35dB",
  "min_duration": 0.8,
  "padding": 0.15,
  "silences": [{"start": 3.900, "end": 5.900}, {"start": 8.900, "end": 10.100}
],
  "kept": [{"start": 0.000, "end": 4.050}, {"start": 5.750, "end": 9.050}, {"start": 9.950, "end": 11.100}
],
  "cut_seconds": 2.600,
  "new_duration": 8.500
}
```

## How it works

1. `ffprobe` reads the duration and confirms the input has an audio stream.
2. `ffmpeg silencedetect` finds silent regions (`noise=<threshold>`,
   `d=<min-duration>`); a trailing silence with no end marker is closed at
   the file duration.
3. Each silence is shrunk by `--padding` on both sides; silences that vanish
   after padding are kept as-is.
4. The kept segments become the complement ranges, rendered as
   `aselect='between(t,a,b)+...'` (+ `select` for video) with `asetpts` /
   `setpts` re-timing, so audio and video stay in sync.
5. In `--apply` mode the file is re-encoded (video: libx264 CRF 23,
   audio: AAC 128k); otherwise nothing is written.

## Limitations

- Cutting is **not lossless**: `--apply` re-encodes the output. Video is
  re-encoded with libx264 (CRF 23, veryfast), so quality and file size change
  slightly; boundaries are frame-accurate, not sample-accurate, and the
  output can differ from the plan by a few tens of milliseconds (AAC priming,
  frame rounding).
- Silence detection is energy-based: quiet room tone above `--threshold`
  counts as sound, and very quiet speech below it counts as silence. Tune
  `--threshold` for your mic.
- Only the first audio stream and first video stream are processed; extra
  streams/subtitles are dropped in `--apply` mode.
- Input must be a seekable media file readable by ffmpeg; pipes/stdin are
  not supported.

## Development

```bash
bash test.sh   # 18 tests, fixtures generated with ffmpeg lavfi (nothing committed)
```

## License

MIT

---
Ringkasan (Bahasa Indonesia): silence-cutter memotong bagian hening dari file
audio/video memakai ffmpeg. Mode default hanya menampilkan rencana potongan
(tabel segmen) tanpa mengubah file apa pun; tambahkan `--apply -o` untuk
meng-encode hasilnya. Mendukung output JSON dan EDL untuk pipeline, berjalan
penuh offline tanpa dependensi selain ffmpeg/ffprobe. Batasan utama: hasil
`--apply` di-encode ulang (bukan lossless) dan deteksi hening berbasis level
energi sehingga `--threshold` perlu disesuaikan dengan rekamanmu.
