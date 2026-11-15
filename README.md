# Hyperspace for macOS

[![tests](https://github.com/fiazsami/hyperspace/actions/workflows/tests.yml/badge.svg)](https://github.com/fiazsami/hyperspace/actions/workflows/tests.yml)

<img src="thumbnail.png" alt="Hyperspace screen saver" width="240" align="right">

Hyperspace is Terence M. Welsh's screen saver that flies the viewer through a wormhole. It comes from the Really Slick Screensavers collection and was ported to macOS by Nick Zitzmann. This fork adds a C++ test suite and continuous integration, fixes five latent defects found while writing the tests, and moves the project to macOS 26. Coverage is measured by a line-coverage gate in [fiazsami/screen-savers](https://github.com/fiazsami/screen-savers).

## What changed in this fork

The work was done between 21 and 23 August 2026: 42 commits, merged through 17 pull requests.

| Area | Result |
| --- | --- |
| Tests | 189 test cases in a single-binary C++17 harness ([`tests/harness.h`](tests/harness.h)): self-registering `TEST()` cases, with no third-party framework |
| Coverage | Line coverage of the C++ core (`rsMath`, `Implicit`, `Rgbhsl`, `util`; 2,388 lines) rose from **5.4% to 96.5%**, measured with clang source-based coverage (`llvm-cov`) |
| Defects | Five latent defects in the shared core, found while writing tests (see below) |
| Test quality | Fixes were checked by deliberately re-introducing the bug (mutation testing), and the commit messages record the result. For example, [`d2e9cb4`](https://github.com/fiazsami/hyperspace/commit/d2e9cb4) records three mutants, all caught. Not every fix is pinned this way: the dead-code fix has no test |
| Platform | Deployment target moved from macOS 10.9, which no longer links, to [macOS 26](https://github.com/fiazsami/hyperspace/commit/016a684). Signing is ad hoc, with no developer team in the project; CI enforces both |
| CI | [GitHub Actions](.github/workflows/tests.yml) builds and runs the test suite, builds Release and Debug with `xcodebuild`, and verifies the code signature |

Drawing code that calls OpenGL directly (`Hyperspace/*.cpp`, `HyperspaceView.mm`) is outside the coverage scope.

## Defects found and fixed

| Defect | Effect | Fix |
| --- | --- | --- |
| Vertex-buffer names generated in the `impSurface` constructor | Crashed without an OpenGL context, so `impCubeVolume` could not be constructed in a test at all; invisible to the running saver | [`d2e9cb4`](https://github.com/fiazsami/hyperspace/commit/d2e9cb4) |
| `impCubeVolume::frame` never initialized | The surface cache could report a false hit on the first frame; harmless in the saver | [`6ee74da`](https://github.com/fiazsami/hyperspace/commit/6ee74da) |
| The same frame counter wrapped at 65,536 | The same false hit returned after the wrap; review found the first fix was only half a fix | [`09544e1`](https://github.com/fiazsami/hyperspace/commit/09544e1) |
| Unsigned clamp of out-of-volume crawl points | Points were sent to the far face of the volume instead of the near one; no visible effect today | [`8e1ed5b`](https://github.com/fiazsami/hyperspace/commit/8e1ed5b) |
| `#ifdef` where every call site used `#if USE_TRIANGLE_STRIPS` | Dead code was compiled in | [`c647bbb`](https://github.com/fiazsami/hyperspace/commit/c647bbb) |

The C++ core is shared with [Helios](https://github.com/fiazsami/helios). Each core fix landed in both repositories as a matched pair of pull requests.

## Build and test

You need macOS 26 and Xcode, or the Xcode command-line tools for the tests alone.

- **Tests:** compile every source under `rsMath`, `Implicit`, `Rgbhsl`, `util` and `tests` with `clang++ -std=c++17`, link with `-framework OpenGL`, and run the binary. The exact steps are in [`.github/workflows/tests.yml`](.github/workflows/tests.yml).
- **Screen saver:**

  ```sh
  xcodebuild -project Hyperspace.xcodeproj -target Hyperspace -configuration Release build
  ```

  Then double-click the built `Hyperspace.saver` to install it.

## How the work was done

The tests, fixes and reviews were written by coding agents (Claude Code) running inside a harness, under the direction of [Fiaz Sami](https://github.com/fiazsami). The harness provides a coverage ratchet, guard hooks and a separate verifier agent. Every change reached `master` through a pull request, with CI from the second one onward; review findings, and the fixes they prompted, are recorded in pull request comments and commit messages. The harness, the coverage data and dated write-ups of what went wrong are in [fiazsami/screen-savers](https://github.com/fiazsami/screen-savers).

## Credits and license

- Hyperspace © 1999–2010 Terence M. Welsh.
- macOS port © 2006 Nick Zitzmann ([nickzman/hyperspace](https://github.com/nickzman/hyperspace)).
- Licensed under the GPL, version 2 or later ([`LICENSE.txt`](LICENSE.txt)). The core libraries (`rsMath`, `Implicit`, `Rgbhsl` and others) are LGPL-2.1 or later, per their file headers. The macOS view files (`*View.h`, `*View.mm`) carry their own copyright notices with no separate license grant; see their headers.
