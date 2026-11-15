# GL → Metal parity

`parity` answers one question for the Metal port: **does the Metal shader draw
what the shipped OpenGL saver draws?** It runs Hyperspace's unmodified OpenGL
code offscreen, records every draw call with the GL state behind it, replays
those draws through the shaders in `metal/`, and compares the two images shot by
shot. There are no stored golden images: both sides render the same frame in the
same process, so the reference is always the real renderer on this machine.

```bash
parity/build.sh                                   # -> .parity-build/parity
.parity-build/parity goo metal .parity-build/out/goo
parity/killcheck.sh                               # every rule, both directions (~5 min)
```

Each shot writes `NNNNN_gl.png`, `NNNNN_metal.png` and `NNNNN_diffx8.png`
(per-pixel difference ×8). The diff image is the first thing to look at when a
pass fails.

## Passes

| pass | what is judged | shader | run |
|---|---|---|---|
| `stars` | stars, sun, lens flare (GL fixed function) | `metal/FixedFunction.metal` | 60 s, 12 shots |
| `goo` | the GLSL goo program: cube-mapped normals, reflection, Fresnel | `metal/Goo.metal` | 60 s, 12 shots |
| `tunnel` | the GLSL tunnel program: two caustic textures, two octaves | `metal/Tunnel.metal` | 2 min, 36 shots |

Stars draw in every pass, through `FixedFunction.metal`. The tunnel needs two
minutes because one rarely puts the camera inside a tunnel; most shots of the
first minute are under 1% lit.

## The rule

A shot passes when, over pixels lit (any channel > 8) in **either** image:

- the share more than 2 levels off is at most `max2`,
- the share more than 8 levels off is at most `max8`, and
- the signed mean difference, Metal minus GL, worst channel, is at most 0.06 levels.

Any draw the recorder could not capture also fails the shot, and a pass that drew
nothing in any shot is an error rather than a pass.

Rates are over lit pixels, not the frame. Star frames are 0.3–4% lit, and a
per-frame rate diluted every defect below 1%.

| pass | max2 | max8 | correct translation, worst shot | weakest defect, worst shot |
|---|---|---|---|---|
| `stars` | 1.0% | 0.1% | 0.00% / 0.00% / bias 0.003 | fog scale ×1.1: 14.14% / 4.17% / bias 0.998 |
| `goo` | 8.0% | 2.5% | 5.28% / 1.35% / bias 0.012 | fog scale ×1.1: 9.65% / 3.05% / bias 0.357 |
| `tunnel` | 3.0% | 0.6% | 1.50% / 0.28% / bias 0.012 | radial fog: 4.81% / 0.28% / bias 0.197 |

Every limit was fixed from measurements like these **before** any candidate
shader was scored, and `killcheck.sh` re-proves the separation on every run.
Loosening a limit to let a shader through defeats the instrument; if a correct
shader fails, find out why first.

### Why goo and tunnel are looser

A faithful translation of either GLSL program leaves a residual: single pixels,
symmetric (GL brighter exactly as often as Metal), on goo silhouettes and on
distant, heavily minified tunnel texture. Nine causes were tested and ruled out —
MVP precision (three formulations, byte-identical), fast-math, explicit
gradients, forced level-0 sampling, texture precision, half-precision maths,
8-bit vertex colour, stale texture copies; forcing GL to seamless cube filtering
moved it only slightly. **The cause is not known.** Because the residual is
symmetric it averages out, while a real translation error pushes one way, so
signed bias separates the two cases where the |diff| rates alone do not.

## What makes it deterministic

- `time()` and `srand()`/`rand()` are defined in the tool. Hyperspace's
  `srand(time(NULL))` gets a fixed seed, and its `rand()` calls get a private
  copy of macOS libc's generator (Park–Miller, checked equal to libc over 1.2M
  values). The private copy matters: something else in the process calls the
  shared `rand()` at timing-dependent moments, and same-seed runs drifted apart
  without it.
- The frame time is fixed at 1/60 s.
- Textures are copied out of GL with every mip level, so texture and mip
  generation are identical on both sides by construction.

Two runs of the same pass produce identical output.

## Kill-check fixtures

`parity/defects/<pass>_<defect>.metal` is the committed shader for that pass
with one deliberate defect: constants carried over from the other shader,
swapped or flipped texture coordinates, radial instead of planar fog, a dropped
term. `killcheck.sh` requires every one to FAIL. When a shader in `metal/`
changes, regenerate the fixtures from the new text rather than editing the
rule.

## Limits

- **One machine.** Calibrated on an Apple M5 Max under macOS 26. Another GPU or
  driver may move the residual; rerun the kill-check before trusting a verdict
  there.
- **Not in CI.** A hosted runner's GPU is virtualised and uncalibrated, so a
  verdict there would mean nothing yet. This runs locally.
- **The replay reuses GL's matrices.** A real port computes them itself, which
  can add a small error this does not measure.
- **The starburst is never judged.** It is dormant for the first five minutes.
- **It is a comparison, not a renderer.** Nothing here draws the saver; the
  shaders in `metal/` are what a Metal renderer would use.
