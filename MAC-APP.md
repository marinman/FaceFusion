# FaceFusion — native macOS app + multi-face swapping

This is a modified copy of [facefusion/facefusion](https://github.com/facefusion/facefusion)
by Henry Ruhs, kept under its original **OpenRAIL-AS** license (see `LICENSE.md`),
including that license's use restrictions. Upstream does the face-swapping; the
additions here are a native front end and per-face source mapping.

## What was added

**A native SwiftUI app** (`mac-app/`) that replaces the Gradio web UI:

- `FaceFusionApp.swift` — the whole interface: a three-column `NavigationSplitView`
  (sections / detected faces / canvas), a Speed preset, a log viewer, and a
  link bar that downloads a video with `yt-dlp` before you swap anything.
- `ff_helper.py` — a small JSON bridge the app shells out to: `info`, `preview`
  and `faces` for a target file. Rendering calls `facefusion.py headless-run`,
  so no engine logic is duplicated in Swift.

**Multi-face swapping** — a different photo for each face in the same video:

- `facefusion/face_map.py` — maps *face slot → source image*, re-detects the
  faces in the reference frame and matches each target face by embedding
  distance, so slots follow identity rather than position.
- `facefusion/processors/modules/face_swapper/core.py` — `process_frame_with_face_map()`.
- `facefusion/uis/components/face_mapper.py` — the equivalent rows in the web UI.
- `--face-map "1=/path/a.png" "2=/path/b.png"` on `headless-run`.

## Building the app

```bash
cd mac-app
swiftc -O -parse-as-library FaceFusionApp.swift -o FaceFusionNative
```

Then drop the binary into an app bundle's `Contents/MacOS/`. The engine itself
is installed the usual upstream way (`python install.py`), and the app expects
it at `~/facefusion` with its venv at `.venv`.

## Notes

- Downloads prefer H.264; VP9 or AV1 is re-encoded afterwards, since QuickTime
  cannot decode those even inside an `.mp4`.
- Rendering uses CoreML with `--execution-thread-count` and a hardware H.264
  encoder. The first render after changing model or detail pays a one-off
  CoreML compile — the second run is the honest timing.
- Only swap faces of people who agreed to it. The upstream license's use
  restrictions apply to this copy too.
