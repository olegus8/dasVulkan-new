# Recording tutorial videos

dasVulkan ships its tutorial site at `doc/source/` with an `.mp4` per scene.
Each scene already produces its mp4 via a **per-tutorial recording driver** —
a separate `.das` file that re-renders the scene parametrically (one frame per
integer index, deterministic), streams the result through an APNG intermediate,
then ffmpeg-muxes a daStrudel music bed onto it. The tutorial source itself is
**never modified** for recording; the driver is the only thing the recording
pipeline touches.

This page documents what's already in the repo, plus the voice + caption
layer we are about to add on top of it.

Recordings are produced on **Boris's PC**, eyeballed + listened-to before they
ship, and **not** validated by CI — so this is a workflow doc, not a test gate.
The reproduction table at the end has enough for someone else to recreate the
setup; nothing is engineered for portability.

## Where things live

```
tutorials/
  recording/
    tutorial_record.das         silent-path utility (capture_apng + convert_to_mp4)
    tutorial_record_voiced.das  voiced extension (say + prepare_voiceover + convert_to_mp4_voiced)
  <NN>_<scene>/
    <scene>_tut.das             the tutorial itself — never edited for recording
    <NN>_<scene>.rst            uses `.. video:: <scene>.mp4`
    <scene>.mp4                 TRACKED — the committed deliverable
    recording/
      record_<scene>.das        the driver (this is what you run)
      <scene>.apng              intermediate, gitignored
      <scene>_bed.wav           music bed, gitignored
      voiceover/                voice + caption manifests (planned), gitignored
```

`.gitignore` already excludes `tutorials/**/recording/{*.apng,*.wav,*.png}` and
the Sphinx build-time copy at `doc/source/_static/tutorials/`. The mp4 under
`tutorials/<scene>/<scene>.mp4` is the source of truth; `doc/source/conf.py`
copies every `tutorials/**/*.mp4` into `_static/tutorials/` at doc build time
and raises on **basename collisions** (so two tutorials cannot ship `foo.mp4`).
That collision check is the only CI gate; Sphinx does not validate that a
`.. video:: foo.mp4` resolves to a real file.

## The shared utility (`tutorials/recording/tutorial_record.das`)

Two public functions, both backend-agnostic — no Vulkan dependency, just
`stbimage` + `ffmpeg`:

```daslang
def public capture_apng(apng_path : string; w, h, n_frames, frame_ms : int;
                        render : block<(frame : int) : array<uint8>>) : bool
```
Streams a parametric render-block to APNG via `stbi_apng_begin` /
`stbi_apng_frame` / `stbi_apng_end`. The block returns one `w*h*4` RGBA8 buffer
per frame index. Rows are flipped in place so the writer's GL-style top-down
flip cancels out (Vulkan readback is already top-down). Returns `true` on
success.

```daslang
def public convert_to_mp4(apng_path, music_feature, daslang_exe, out_mp4 : string;
                          dur_s : float; fps, bed_db, fade_ms : int) : bool
```
Renders a daStrudel music bed (`music_feature` is a daslang feature path) to
`dur_s` seconds via a subprocess, then ffmpeg-muxes APNG + faded
(`afade` in/out by `fade_ms`) + attenuated (`bed_db`) audio into `out_mp4`.
`-c:v libx264 -crf 23 -pix_fmt yuv420p +faststart`. Returns `true` on success.

`find_daslang_exe(das_root)` rounds out the helpers — probes the usual
Windows / Linux / macOS layouts and falls back to bare `daslang` on PATH.

## The driver (canonical exemplar: `record_triangle.das`)

```daslang
options gen2
require ../triangle_tut.das
require ../../recording/tutorial_record.das
require daslib/fio
require daslib/module_path
require math

[export]
def main {
    let here = get_this_module_dir()
    let apng = path_join(here, "triangle.apng")
    let out_mp4 = path_join(dir_name(here), "triangle.mp4")
    let das_root = get_das_root()
    let daslang_exe = find_daslang_exe(das_root)
    let music = path_join(das_root, "examples/daStrudel/features/sf2_integration_full_ambient.das")

    let n_frames = 120
    let fps = 30
    let frame_ms = 1000 / fps
    let dur_s = float(n_frames) / float(fps)

    let ok = capture_apng(apng, TRI_W, TRI_H, n_frames, frame_ms) $(frame : int) {
        let angle = float(frame) / float(n_frames) * 2.0f * PI
        return <- render_spin_triangle(angle)
    }
    if (!ok) { panic("capture failed") }
    if (!convert_to_mp4(apng, music, daslang_exe, out_mp4, dur_s, fps, -13, 100)) {
        panic("convert failed")
    }
    to_log(LOG_INFO, "[record] tutorial 01 done\n")
}
```

A driver:

1. **Requires the tutorial's scene module** to reuse its helpers (e.g.
   `render_spin_triangle(angle)` lives in `triangle_tut.das`).
2. **Lays out paths** off `get_this_module_dir()` so caller cwd is irrelevant.
3. **Picks frame count + fps**, computes `dur_s`.
4. **Calls `capture_apng` with a parametric block** — one render per integer
   `frame`. Each render is independent; no state across frames.
5. **Calls `convert_to_mp4`** with the music bed feature path, daslang exe,
   final mp4 path, and the bed parameters (`-13 dB`, `100 ms` fade in/out).
6. **Panics on failure** so a botched recording is loud.

The folder is named `recording/` specifically so the tutorials `.das_test`
skips it in CI (stbimage + audio modules aren't loaded there).

## Run it

```bash
<daslang>/bin/Release/daslang -load_module <dasvulkan> \
    <dasvulkan>/tutorials/01_triangle/recording/record_triangle.das
```

That's the entire pipeline today — one command per tutorial.

## Voice + captions

Layered on top of the existing utility, **without changing how the driver
looks** — `record_triangle.das` keeps working unchanged. The voiced extension
lives in a **separate file** (`tutorial_record_voiced.das`) so the silent
file's compile-check in CI stays clean even when dasHV (the dasOPENAI HTTP
backend) is not loaded; voiced drivers just `require` the voiced file, which
re-exports the silent path. The voiced module adds three calls:

| Function | Role |
|---|---|
| `say(frame : int; caption : string)` / `say(frame, caption, voice)` | Register a caption + voice anchor at frame index `frame` (matches `capture_apng`'s deterministic frame model). Defaults voice to caption. Lines accumulate in a module-private array; recordings run one at a time so a global is the simplest fit (matches dasImgui's `prepare_recording`) |
| `prepare_voiceover(apng_path [, base_url, voice_id, model]) : bool` | For each registered line: hit Kokoro TTS at `http://127.0.0.1:8880/v1` with voice `bf_emma`, write `<apng_dir>/voiceover/line_<i>.wav` (skipped if already on disk, so re-runs are cheap), measure duration |
| `convert_to_mp4_voiced(apng_path, music_feature, daslang_exe, out_mp4, dur_s, fps, bed_db, fade_ms [, font_file]) : bool` | Same shape as `convert_to_mp4` but also mixes each voiceover wav (delayed via ffmpeg `adelay` to its frame's seconds) under the music bed and renders each caption via ffmpeg `drawtext` (timed `enable=between(t, t_start, t_start + dur + 0.4s)`). Codec is tuned for smooth shader-pure content: `-c:v libx264 -tune animation -preset slower -crf 28 -pix_fmt yuv420p -movflags +faststart` (CRF is **five** above the silent path's `-crf 23`: shader-pure content has no skin / film grain so the cosine-palette gradients absorb the bigger quality cut invisibly, and the mp4 ends up about half the size of the silent default). `font_file` defaults to the Windows `arial.ttf` (ffmpeg-escaped form); pass another path on Linux |

A driver that adds voice + captions then looks like:

```daslang
say( 30, "dasVulkan tutorial 2 -- Mandelbrot zoom",
        "das Vulkan tutorial two. The Mandelbrot zoom.")
say(360, "Time drives the animation",
        "One time push constant drives the whole animation. Zoom, rotation, color.")
say(720, "daslang to SPIR-V",
        "Authored in daslang. Lowered to Spear V.")

let ok = capture_apng(...) $(frame) { ... }
if (!prepare_voiceover(apng)) { panic("voiceover failed -- is Kokoro running at :8880?") }
convert_to_mp4_voiced(apng, music, daslang_exe, out_mp4, dur_s, fps, -13, 100)
```

`record_mandelbrot.das` is the canonical voiced exemplar.

### Caption vs voice text — pronunciation conventions

`say(...)` takes **two strings**: a terse on-screen `caption` and a natural
spoken `voice` (which defaults to the caption when omitted). They diverge
because TTS engines don't read brand-name camelCase or hyphenated acronyms the
way a human does — captions stay canonical, voice text is respelled
phonetically for Kokoro / `bf_emma`:

| Canonical (caption) | Voice text |
|---|---|
| `dasVulkan` | `das Vulkan` (split the camelCase — TTS reads it as two natural words) |
| `dasSpirv` | `das Spear V` |
| `SPIR-V` | `Spear V` (Khronos's intended pronunciation per the spec preamble) |
| `daslang` | `daslang` (Kokoro reads it acceptably as written) |
| `2` / `3` / … | `two` / `three` / … (force the word form when it has to read aloud — digit-form is fine in captions) |

`-`, `--`, and other ASCII punctuation in caption text are fine for the eye
but get spelled out by the TTS — strip them from voice text. ASCII-only
applies to both (the Windows / Linux fallback fonts ffmpeg `drawtext` resolves
to don't carry em-dash / arrow / smart-quote glyphs).

**Use periods, not commas, to force pauses.** Kokoro's `bf_emma` runs through
comma-separated phrases at conversational pace; a clear three-beat list like
*"Zoom. Rotation. Color."* (three sentences) sits much better than
*"Zoom, rotation, color."* — the periods land as a deliberate beat, the
captions still read fine, and the line ends with the intended cadence.

### Quality tuning — when to push CRF higher

The voiced default is `-crf 28` (the silent path is `-crf 23` — the libx264
default). That five-step gap was tuned on the mandelbrot scene: same fixture,
`-crf 23` produced ~13.5 MB, `-crf 28` produced 6.95 MB (768×768, 30 s, 900
frames). Eyeballed at 100% on a 4K display — no banding in the cosine palette,
no block artifacts on the fractal edges, no mush on the captions. Both
`-tune animation` and `-preset slower` matter: the tune biases x264 toward
larger blocks (good for smooth gradients, smooth pans, large flat regions —
exactly what shader-pure tutorial content produces), and the slower preset
gives the motion search enough headroom that smooth zooms don't stutter at the
higher CRF.

CRF is logarithmic — each `+6` ≈ half the bitrate. So `-crf 28` ≈ a third of
`-crf 23`'s bitrate, and that's the size win. **Procedure when adding a new
voiced recording:** start at `-crf 28`, eyeball, bump up (`30`, `32`, …) until
artifacts appear, then back off one step. Cosine-palette shader content
tolerates very aggressive CRF; anything with real photographic detail
(textures from disk, blit-from-camera) won't, so default back to `-crf 23`
there. Photographic content lives outside this pipeline today — when it shows
up, expose the CRF as a parameter rather than hard-coding it.

## Reproduction (if it ever has to happen elsewhere)

Recordings are produced on Boris's Windows PC. Moving parts:

| Dependency | Where on Boris's machine |
|---|---|
| Vulkan SDK | `C:/VulkanSDK/1.4.350.0/` (or any matching dasVulkan-CI version) |
| daslang | `D:/Work/daScript/` (master HEAD) |
| dasVulkan | `D:/DASPKG/dasVulkan/` (this repo) |
| daStrudel music feature | `<daslang>/examples/daStrudel/features/sf2_integration_full_ambient.das` (shipped with daslang) |
| Kokoro TTS | `http://127.0.0.1:8880/v1`. Start with: `D:/kokoro/.venv/Scripts/python.exe -m uvicorn server:app --host 127.0.0.1 --port 8880` (cwd `D:/kokoro`). Default voice `bf_emma`. Only needed once voice is wired up |
| ffmpeg | on PATH; any recent build. Must support `libx264` and (for captions) the `drawtext` filter |
| Display | Not required — drivers render headlessly via Vulkan readback in `render_<scene>(frame)`. No window, no swapchain capture |

## Commit structure for a recording

For scene `foo`:

1. Write `tutorials/<NN>_foo/recording/record_foo.das` modeled on
   `record_triangle.das`. The tutorial scene module gains whatever
   `render_foo_frame(...)` helper the driver needs (small, isolated).
2. Run the driver; **eyeball + listen to** the resulting `.mp4`.
3. Commit: `recording: foo` — the driver + the new `render_foo_frame` helper
   + `tutorials/<NN>_foo/foo.mp4`.
4. The tutorial RST gets `.. video:: foo.mp4` in its own page (often the same
   PR; sometimes already in place from the tutorial commit).

## What this is NOT

- **Not an in-tutorial seam.** The tutorial source is untouched. Recording
  lives entirely in a separate driver under `<tutorial>/recording/`.
- **Not a daslang-live host.** No live commands, no HTTP, no env var arming.
  Just `daslang record_foo.das`.
- **Not a windowed-capture pipeline.** Drivers render each frame headlessly to
  a host-visible buffer and read it back; the windowed `show_*.das` viewers
  are for users, not for recording.
- **Not CI.** The `recording/` folder is excluded from the tutorials
  `.das_test`. The only thing CI enforces is the basename-collision gate in
  `doc/source/conf.py`. Boris eyeballs + listens to every recording.
- **Not self-verifying.** Each tutorial has its own pixel oracle (the `[test]`
  in `test_<scene>.das`); the recording driver only produces the doc figure.
