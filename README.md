# s&box, tuned for macOS

This branch collects every macOS performance change from my open pull requests,
rebased onto upstream `master`, together with the KosmicKrisp (Vulkan-on-Metal)
driver changes that go with them. It exists so macOS testers can run all of it
at once instead of stacking thirteen branches by hand.

Nothing here is new. Every commit is an individual PR upstream, listed below;
this branch only puts them in one place.

## What is faster

M3 Max, macOS 27, Apple Silicon, warm caches. Each figure is a median of
several runs against `master` at the same commit.

| | master | this branch |
|---|---|---|
| `./sbox-dev` → launcher window on screen | ~2.1 s | **~0.95 s** (2.2x) |
| `./sbox-dev -project` → editor ready | 21–26 s | **12.5–16 s** (~1.7x) |
| game launch → first menu frame | ~11.1 s | **~5.9 s** (1.9x) |
| launcher backdrop blur, GPU per frame | 56 ms | **6.5 ms** |
| launcher frame rate | 12 fps | **31 fps** |
| benchmark tests after a GPU-heavy scene | 2–3 fps, 1 s stalls | **20–250 fps**, no stalls |

The startup numbers are main-thread time attributed with `dotnet-trace`; the
frame numbers come from the Metal HUD and the benchmark's own frame-time
export.

## Building

Apple Silicon only — s&box ships no x86_64 macOS binaries.

```bash
git clone -b macos-optimized https://github.com/UserDerezzed/sbox-public.git
cd sbox-public
./Setup.sh
```

`Setup.sh` is upstream's setup script with a driver step added. It downloads the
prebuilt native binaries and content for the upstream commit this branch sits on
(about 8 GB), builds the managed engine, compiles shaders and content, installs
the git hooks that keep artifacts current across pulls, and then builds and
installs the driver. Expect roughly 20 minutes on the first run, most of it the
download and the driver build. Re-running it only redoes what is out of date.

You need the [.NET 10 SDK](https://dotnet.microsoft.com/en-us/download) and, for
the driver, a Mesa toolchain:

```bash
brew install meson ninja cmake pkg-config rust
cargo install bindgen-cli
```

If you would rather not build the driver, `./Setup.sh --skip-driver` builds the
engine against the bundled one. You keep the startup and blur work and lose the
driver rows in the table below.

```
./Setup.sh --skip-driver      engine only, leave the installed driver alone
./Setup.sh --driver-only      rebuild and reinstall the driver only
./Setup.sh --clean-driver     reconfigure the driver build from scratch
./Setup.sh --driver-ref REF   build a different driver commit or branch
./Setup.sh --verbose          full build output
```

Then:

```bash
cd game
./sbox-dev                                      # editor
./sbox                                          # game
./benchmark +benchmarks facepunch.benchmark     # benchmark suite
```

> **Anything that re-downloads artifacts puts Facepunch's bundled driver back.**
> Restore this branch's driver with `./Setup.sh --driver-only`. Your previous
> driver is kept beside it as `libvulkan_kosmickrisp.dylib.bundled`.

## What is in it

### Editor launcher startup — ~2.1 s → ~0.95 s

| Change | Cost removed | Before → after |
|---|---|---|
| [#11840](https://github.com/Facepunch/sbox-public/pull/11840) Boot the panel app's managed side alongside the native engine | type library, fonts and stylesheet parse serialised on the main thread | 840 ms → ~120 ms |
| [#11837](https://github.com/Facepunch/sbox-public/pull/11837) Skip the AppKit show animation on panel windows | first display link enumerates every display mode | ~500 ms → ~290 ms |
| [#11839](https://github.com/Facepunch/sbox-public/pull/11839) Find a running instance with a mutex off Windows | enumerating every process on the machine | ~130 ms → ~85 ms |
| [#11838](https://github.com/Facepunch/sbox-public/pull/11838) Don't load the engine to hand `sbox-dev` off to the launcher | jitting `Main` pulled in `Sandbox.Engine.dll` | ~170 ms → ~135 ms |

### Editor startup — 21–26 s → 12.5–16 s

| Change | Cost removed | Before → after |
|---|---|---|
| [#11841](https://github.com/Facepunch/sbox-public/pull/11841) Watch folders with FSEvents on macOS | 49 × `FileSystemWatcher`, 50–100 ms each on the main thread | 5,160 ms → ~0 ms |
| [#11842](https://github.com/Facepunch/sbox-public/pull/11842) Don't read trusted assemblies with Cecil up front | full Cecil parse of every local package assembly | 1,100 ms → 8 ms |
| [#11843](https://github.com/Facepunch/sbox-public/pull/11843) Read Steam item definitions lazily | a dozen `GetDefinitionProperty` calls per item, plus a 5 s bootstrap wait | ~1,000 ms → 0 ms |
| [#11844](https://github.com/Facepunch/sbox-public/pull/11844) Generate the solution off the main thread | `GenerateSolution` awaited mid-load | 900 ms → 0 ms |

### Game startup — ~11.1 s → ~5.9 s

| Change | Cost removed | Before → after |
|---|---|---|
| [#11846](https://github.com/Facepunch/sbox-public/pull/11846) Cache the menu's compiled assembly for the game | Roslyn rebuild of 35 `.cs` and 209 `.razor` on every launch | 3,460 ms → 0 ms on a cache hit |
| [#11847](https://github.com/Facepunch/sbox-public/pull/11847) Don't enumerate display modes on the menu's critical path | `SDL_GetFullscreenDisplayModes` comparing every mode against every other | 980 ms → 70 ms |
| [#11848](https://github.com/Facepunch/sbox-public/pull/11848) Generator: only bind calls that pass a string literal | Roslyn extension-method lookup per invocation | 3,460 ms → 2,600 ms per compile |
| [#11849](https://github.com/Facepunch/sbox-public/pull/11849) Split `ResetEnvironment` into teardown and setup | type library rebuild + `GC.Collect` on a fresh environment | ~700 ms → ~140 ms |

### Rendering

| Change | What it does |
|---|---|
| [#11833](https://github.com/Facepunch/sbox-public/pull/11833) Blur panel filter layers from a gaussian mip chain | `filter: blur()` sampled the full-res layer 225 times per pixel. Reads a gaussian mip chain instead: launcher backdrop 56 ms → 6.5 ms of GPU, 12 → 31 fps |
| Fix benchmark percentiles throwing with few samples | `Percentile` indexed `[-1]` with fewer than 19 samples, dropping 3–4 scenes a run from the macOS benchmark results |

### Driver — [UserDerezzed/mesa-kosmickrisp@macos-optimized](https://github.com/UserDerezzed/mesa-kosmickrisp/tree/macos-optimized)

| Change | What it does |
|---|---|
| [#7](https://github.com/Facepunch/mesa-kosmickrisp/pull/7) Fetch the drawable at present instead of at acquire | A drawable was owned from acquire through present, so acquiring ahead of presents orphaned drawables that Core Animation only reclaimed after a one-second timeout. Fixes the stall that left 11 benchmark tests at 2–3 fps: `light.point` 2.5 → 45.5 fps, `ui.text` 3.3 → 248.8 fps |
| [#5](https://github.com/Facepunch/mesa-kosmickrisp/pull/5) Link weak entrypoints through a stub library | 3,041 flat-namespace binds made dyld search every loaded image. `SourceEnginePreInit` 560–650 ms → 250–300 ms in the launcher, 1.4 s → 0.3 s in the editor |
| [#6](https://github.com/Facepunch/mesa-kosmickrisp/pull/6) Create a disk shader cache | `disk_cache_create` was never called, so every pipeline recompiled SPIR-V → NIR → MSL in every process. Launcher first frame ~290 ms → ~180 ms |
| [#2](https://github.com/Facepunch/mesa-kosmickrisp/pull/2) Don't expose `VK_KHR_present_wait`/`present_id` | The engine waits on the last present every frame, which on Metal means waiting for the compositor round trip. Launcher 31.6 → 95.9 fps. **See the caveat below** |
| Merge consecutive single-pass command buffers (thanks [@PolEpie](https://github.com/PolEpie)) | The engine submits ~10 single-pass command buffers at a time, each costing a full tile store and reload. Merging them saved ~7 ms of GPU on a Fishport frame (M1 Pro) |
| Seven MSL and residency changes | Branch-free robust SSBO loads and vectorised UBO loads, branch-free null-descriptor reads, packed vectors for scratch, cached device residency snapshots, 32-bit visibility-heap query indices |

## Caveats

- **Everything here was measured on Apple Silicon**, mostly an M3 Max on macOS
  27, with some driver work benchmarked on an M1 Pro. The engine changes are
  cross-platform and several help Windows and Linux too, but only the macOS
  numbers are measured.
- **Dropping `present_wait` ([#2](https://github.com/Facepunch/mesa-kosmickrisp/pull/2))
  is not settled.** Without it the renderer falls back to waiting for the queue
  to go idle each frame, so the CPU and GPU stop overlapping. That is a large
  win for the launcher and it has not been shown to be a win for GPU-heavy
  editor or game scenes. If you are benchmarking a real workload, this is the
  first thing to try reverting.
- **Shaders must be compiled.** The downloaded artifacts carry upstream's
  compiled `.shader_c`, and this branch changes three shader files. `Setup.sh`
  does this for you; if you build by hand and skip the shader step, the blur
  work silently does nothing and mismatched shaders can leave UI text invisible.
- The driver is built locally and unsigned. `Setup.sh` clears the quarantine
  attribute after installing it.

## Reporting results

Useful things to include: your Mac model and macOS version, whether you built
the driver or used `--skip-driver`, and for frame rates the benchmark's own
export rather than an eyeballed HUD number:

```bash
cd game && ./benchmark +benchmarks facepunch.benchmark
```

---

<div align="center">
  <img src="https://sbox.game/img/sbox-logo-square.svg" width="80px" alt="s&box logo">

  [Website] | [Getting Started] | [Forums] | [Documentation] | [Contributing]
</div>

[Website]: https://sbox.game/
[Getting Started]: https://sbox.game/learn/getting-started
[Forums]: https://sbox.game/f/
[Documentation]: https://sbox.game/dev/doc/
[Contributing]: CONTRIBUTING.md

# s&box

[s&box](https://sbox.game) is a modern game engine, built on Valve's Source 2 and the latest .NET technology, it provides a modern intuitive editor for creating games.

![s&box editor](https://cdn.sbox.game/about/editor.webp)

If your goal is to create games using s&box, please start with [getting started guide](https://sbox.game/learn/getting-started).
This repository is for building the engine from source for those who want to contribute to the development of the engine.

## Getting the engine

### Steam

You can download and install the s&box editor directly from [Steam](https://store.steampowered.com/app/590830/sbox/).

### Compiling from source

This repository contains the C# engine, editor, tooling and game content. The native Source 2 core is
distributed as prebuilt binaries that setup downloads for your platform, so no C++ toolchain is needed.

| Platform | Setup | Notes |
|----------|-------|-------|
| Windows 10 / 11 (x64) | `Setup.bat` | |
| Linux (x64) | `./Setup.sh` | Binaries target the Steam Linux Runtime, most distros should work. |
| macOS (Apple Silicon) | `./Setup.sh` | Intel Macs are not supported. |

#### Prerequisites

* [Git](https://git-scm.com/downloads)
* [.NET 10 SDK](https://dotnet.microsoft.com/en-us/download)
* An IDE for the C# code is recommended: [Visual Studio 2026](https://visualstudio.microsoft.com/) or
  [Rider](https://www.jetbrains.com/rider/) on Windows, Rider or [VS Code](https://code.visualstudio.com/) on Linux and macOS.

#### Setup

```bash
# Clone the repo
git clone https://github.com/Facepunch/sbox-public.git
cd sbox-public

# Windows
Setup.bat

# Linux / macOS
./Setup.sh
```

Once setup completes, the game (sbox) and editor (sbox-dev.exe) run from the `game` folder.

#### Staying up to date

Pulling on Git will run a hook that fetches any new native binaries or content that changed and regenerates the interop bindings. Build the C# code from your IDE as usual, or rerun `Setup.bat` for a full incremental rebuild including shaders and content.

## Contributing

If you would like to contribute to the engine, please see the [contributing guide](CONTRIBUTING.md).

If you want to report bugs or request new features, see [sbox-issues](https://github.com/Facepunch/sbox-public/issues/).

## Documentation

Full documentation, tutorials, and API references are available at [sbox.game/dev/](https://sbox.game/dev/).

## License

The s&box engine source code is licensed under the [MIT License](LICENSE.md).

Certain native binaries in `game/bin` are not covered by the MIT license. These binaries are distributed under the s&box EULA. You must agree to the terms of the EULA to use them.

This project includes third-party components that are separately licensed.
Those components are not covered by the MIT license above and remain subject
to their original licenses as indicated in `game/thirdpartylegalnotices`.
