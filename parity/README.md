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
parity/killcheck.sh inject                        # the recorder's checks alone (~30 s)
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

Any draw the recorder could not capture -- or captured under GL state the replay
does not reproduce (a blend other than `(SRC_ALPHA, ONE)`, a texture mode other
than MODULATE, a program, cube map or texgen on the fixed-function path, an
alpha-only texture, a texture name with no image) -- fails the shot as
"unrecorded GL draw calls". A pass that drew nothing in any shot is an error
rather than a pass.

The recorder intercepts a fixed set of GL entry points, so it does not rely on
that set being complete:

- **Primitive count.** GL counts the primitives it generates in each shot
  (`GL_PRIMITIVES_GENERATED`), and the shot fails unless the count equals the
  triangles recorded. A draw through an entry point the recorder does not see
  (`glDrawArrays`, `glCallLists`, `glVertex2f`) shows up as
  "GL drew N primitives, M recorded".
- **Current color and texcoord.** After every recorded draw, GL's current
  color and texcoord must equal the recorded ones. A mismatch means one was set
  through an entry point the recorder does not see (`glColor4ub`,
  `glTexCoord2d`), and the draw is refused.
- **No GL error.** A shot frame that raises one fails as "GL error": some call,
  the saver's or the recorder's, did not do what the recording assumes.

Display lists are recorded when compiled and refused if they set their own
color, bind more than one texture, draw anything but triangle strips, or call
another list, or change a texture, and a call made between `glBegin` and
`glEnd` is refused. A `glNewList` that GL refuses (inside an open list, inside
`glBegin`, list 0) opens nothing, as in GL. Draws made while a
`GL_COMPILE_AND_EXECUTE` list is open are refused: everything there is compiled
too, including the calls the recorder makes to inspect state. Compiling a name again replaces its list. Vertices issued before a
list's first `glTexCoord` take the texcoord current at call time, as GL does.

Textures and their sampler settings are copied after the frame has drawn, so
changing a texture during a shot frame fails the shot: the copy would hold the
final state for draws GL made with the earlier one. That covers `glTexImage2D`,
`glTexSubImage2D`, `glCopyTex*Image2D`, `glTexParameter{i,f,iv,fv}`,
`glDeleteTextures`, and `gluBuild2DMipmaps` (which Hyperspace no longer calls:
its mip chains are built on the CPU and uploaded level by level). It does not
cover `glGenerateMipmap`, compressed, 1D or 3D uploads,
`gluBuild2DMipmapLevels`, or `glTexParameterI*`; Hyperspace uses none, and
changes textures only at start-up. The copies are dropped after every shot, so a change between shots is
picked up.

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
8-bit vertex color, stale texture copies; forcing GL to seamless cube filtering
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

The recorder's checks have fixtures too, as `inject=<case>`: parity draws one
known fault at the end of every shot, through the same interposers the saver
uses; `parity --inject-cases` lists them, and `killcheck.sh` runs every one. The
refused cases draw with alpha 0 or off screen, and `killcheck.sh` counts one as
killed only if the recorder refused it, the image stayed within limits, and no
GL error was raised, so a case cannot pass by failing for some other reason. The
`*_ok` cases draw something the recorder must replay correctly, and they must
pass. Each case is the shape one check exists for, and removing that check lets
the case through. Where a check spans several entry points (the texture-change
interposers, the color setters), the case exercises one of them.

## Seam check

`parity/seamcheck.sh <ref>` answers a different question from the passes: **did a
change to how Hyperspace draws leave the picture alone?** It builds `parity` at
`<ref>` in a worktree under `.parity-build/seam/`, runs the passes on that tree
and on the working tree, and compares the two runs' GL images with
`parity --compare`. Both sides are the GL renderer, so the comparison has no
translation residual and its rule is tighter than any pass's: per shot, at most
0.1% of lit pixels off by more than 2 levels, 0.01% by more than 8, and a signed
bias of 0.06.

```bash
parity/seamcheck.sh master            # all three passes, ~3 min
parity/seamcheck.sh master stars      # one pass
```

`master` against itself compares at exactly 0. Moving the camera maths off the GL
matrix stack (`Hyperspace/transform`) measured 0.000% / 0.005% / 0.015% worst
lit>2 for stars / goo / tunnel: float rounding on a few edge pixels. A camera
roll sign flip, a field of view 0.5 degrees off, a billboard heading 0.3 rad off
and a stuck star stretch each come out DIFFERENT at about 100%.

Moving the stars and the lens flare onto `HSRenderer` (`Hyperspace/renderer.h`),
each quad drawn from a CPU-built model matrix, measured 0.003% / 0.000% / 0.002%
worst lit>2, no pixel more than 3 levels off. (A first version that rounded the
corners in world space instead measured 0.024% / 0.002% / 0.023%: the seam
check sees that precision.) A star core 10% too large and a flare plane 2% too
wide come out DIFFERENT at 9.8% and 43.7%.

Moving every texture onto `HSRenderer` -- mip chains built on the CPU by
`hsBuildMipmaps`, which matches Apple's `gluBuild2DMipmaps` byte for byte, and
the caustics rendered offscreen and read back -- compared at exactly 0 against
the star and flare seam. Mip rounding one level off, the caustics' red
refraction scaled by 1.1 and two cube-map faces swapped come out DIFFERENT at
6.4% (goo), 17.9% (tunnel) and 6.8% (goo).

## Limits

- **One machine.** Calibrated on an Apple M5 Max under macOS 26. Another GPU or
  driver may move the residual; rerun the kill-check before trusting a verdict
  there.
- **Not in CI.** A hosted runner's GPU is virtualized and uncalibrated, so a
  verdict there would mean nothing yet. This runs locally.
- **The replay reuses GL's matrices.** A real port computes them itself, which
  can add a small error this does not measure.
- **The starburst is never judged.** It is dormant for the first five minutes,
  and past that it is drawn with the goo program from a display list, which the
  recorder refuses: a run long enough to reach it fails with "unrecorded GL draw
  calls" rather than a verdict on any shader.
- **It is a comparison, not a renderer.** Nothing here draws the saver; the
  shaders in `metal/` are what a Metal renderer would use.
