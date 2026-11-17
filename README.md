FaceFusion — native macOS app
=============================

A native macOS front end for **[FaceFusion](https://github.com/facefusion/facefusion)**,
plus multi-face swapping and a built-in video downloader.

Credit where it belongs
-----------------------

All of the face-swapping work — the models, the processors, the pipeline, the
engine this app drives — is **[facefusion/facefusion](https://github.com/facefusion/facefusion)**
by **Henry Ruhs** and its contributors. This repository is a modified copy of
that project and keeps its original **OpenRAIL-AS** license, including the use
restrictions in [`LICENSE.md`](LICENSE.md). Upstream's own documentation is
preserved at [`README-upstream.md`](README-upstream.md) and
[docs.facefusion.io](https://docs.facefusion.io).

Nothing here improves the swapping itself. What is added is a Mac interface on
top of it, per-face source mapping, and a downloader.

What this adds
--------------

### A native SwiftUI app

`mac-app/FaceFusionApp.swift` replaces the Gradio web UI with a real Mac window:
a three-column `NavigationSplitView` (sections / detected faces / canvas), a
frame scrubber, a Speed preset, and a log viewer. `mac-app/ff_helper.py` is a
small JSON bridge for file info, preview frames and face detection; rendering
shells out to `facefusion.py headless-run`, so no engine logic is reimplemented
in Swift.

### A video downloader

The link bar at the top of the window takes a video URL and fetches it with
**[yt-dlp](https://github.com/yt-dlp/yt-dlp)**, which does all the actual
downloading and site handling:

- The link is probed first, so a dead link, a private post or an unsupported
  site is reported before anything else happens.
- It **asks where to save** with a standard save sheet, prefilled with the
  video's title, and the file is only saved — never loaded into the app
  automatically. Swapping stays a separate, deliberate step.
- H.264 formats are preferred, and VP9 or AV1 is re-encoded to H.264
  afterwards, because QuickTime cannot decode those even inside an `.mp4`.
- Downloads log to `~/Library/Logs/facefusion-downloads.log`, appended and
  never truncated, so an intermittent failure stays readable.
- When a site demands a session, it retries with the local browser's cookies.
  Nothing is uploaded anywhere.

### Multi-face swapping

A different photo for each face in the same video:

- `facefusion/face_map.py` maps *face slot → source image*, re-detects the faces
  in the reference frame and matches each target face by embedding distance, so
  slots follow identity rather than position.
- `facefusion/processors/modules/face_swapper/core.py` — `process_frame_with_face_map()`.
- `facefusion/uis/components/face_mapper.py` — the equivalent rows in the web UI.
- On the command line: `--face-map "1=/path/a.png" "2=/path/b.png"`.

Building
--------

Install the engine the upstream way (see [`README-upstream.md`](README-upstream.md)),
then:

```bash
cd mac-app
swiftc -O -parse-as-library FaceFusionApp.swift -o FaceFusionNative
```

Copy the binary into an app bundle's `Contents/MacOS/`. The app expects the
engine at `~/facefusion` with its virtualenv at `.venv`, and `yt-dlp` and
`ffmpeg` on the usual Homebrew paths.

Performance notes
-----------------

Rendering uses CoreML with `--execution-thread-count` and a hardware H.264
encoder. The first render after changing the model or detail setting pays a
one-off CoreML compile, so the second run is the honest timing — measured on an
M4 Pro, 60 frames of a 1320×586 clip took 43s on the slowest preset and 18s on
the default one.

Use it responsibly
------------------

Only swap faces of people who have agreed to it. The upstream license's use
restrictions apply to this copy in full — read [`LICENSE.md`](LICENSE.md) before
you do anything with this.
