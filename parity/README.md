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
parity/backendcheck.sh                            # the Metal backend against GL (~2.5 min)
```

Each shot writes `NNNNN_gl.png`, `NNNNN_metal.png` and `NNNNN_diffx8.png`
(per-pixel difference ×8). The diff image is the first thing to look at when a
pass fails.

## Passes

| pass | what is judged | shader | run |
|---|---|---|---|
| `stars` | stars and lens flares (GL fixed function); the sun is never in frame (below) | `metal/FixedFunction.metal` | 60 s, 12 shots |
| `goo` | the GLSL goo program: cube-mapped normals, reflection, Fresnel | `metal/Goo.metal` | 60 s, 12 shots |
| `tunnel` | the GLSL tunnel program: two caustic textures, two octaves | `metal/Tunnel.metal` | 2 min, 36 shots |
| `burst` | the goo, once the starburst's sphere is gone; the sphere is refused (below) | `metal/Goo.metal` | 8 s, 16 shots |
| `sun` | `stars`, with the sun held in view | `metal/FixedFunction.metal` | 20 s, 12 shots |

Stars draw in every pass, through `FixedFunction.metal`. The tunnel needs two
minutes because one rarely puts the camera inside a tunnel; most shots of the
first minute are under 1% lit. Every pass runs with shaders on; nothing here
judges the fixed-function goo and tunnel a user gets with shaders off.

The saver sets off its first starburst after five minutes. `burst` sets one off
itself, at frame 60, ahead of the camera along the path as the saver does, but
at fixed values where the saver draws random ones: 0.75 of the depth ahead
(the saver: 0.5 to 1.0) and height 0 (the saver: -1 to 1). It is placed from
the previous frame's camera; the saver uses the current one. Goo is on, as the
saver's default is, because the sphere draws with the goo's program and
textures. A burst that fails to start is an error, not a pass. It exists for the seam
check: the sphere is drawn with the goo program from a display list, which the
recorder refuses, so every shot until it is gone (about frame 420) FAILs as
"unrecorded GL draw calls", and `killcheck.sh` does not run it. The shots after
that judge the goo with the goo pass's limits.

The sun sits at (0, 2, 0), and no `stars`, `goo` or `tunnel` shot has it in
frame: at every one the path has left it behind the camera or off to the side
(its eye-space depth and projection, printed per shot). Its lens flare still
draws, since the flare needs the sun only in front of the camera, not on
screen. Commenting out the sun's draw compared at exactly 0 on all four passes,
and so did a sun 20 times the size (`stars`, `goo`) and 1000 times (`stars`).
`sun` runs the first 20 s of `stars` with the sun moved, before every frame,
12 units along the last frame's view direction. That is past the fog's end
(`depth`, 9.8 by default), as the saver's sun usually is -- 30 to 60 units out,
1 to 2 pixels across at 1280x720 -- so the pass sees whether the sun draws
unfogged: with fog on it comes out black. The sun is drawn from its last two
positions and stretched by its motion on screen, as every star is; measured, it
lands within 5 by 4 pixels of the middle of every shot. At every shot parity
checks the sun where it was drawn -- in front of the camera, within the middle
half of the frame each way, and farther than the fog's end -- and the run
errors out (exit 2) if not, so the pass cannot quietly become a stars pass. Without the sun's draw, or with `setFog(false)` doing nothing,
every shot comes out DIFFERENT, by 0.26% to 0.75% of lit pixels.

Only the sun moves: its lens flare is still drawn for (0, 2, 0). Drawn on the
sun instead, at 20 units, the flare's core hides it -- removing the sun's draw
then compared at exactly 0 -- so judging the two together would judge the
flare alone.

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
term. `killcheck.sh` requires every one to FAIL. `sun` judges with the
`stars` pass's shader, and its one fixture is the defect only it can see:
`sun_fogalways` fogs every draw, the sun's included. The only other draws with
fog off are the lens flares, in the overlay plane at eye depth 0, where fog
changes nothing -- so under `stars` that fixture passes. When a shader in `metal/`
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
parity/seamcheck.sh master            # every pass, ~3.5 min
parity/seamcheck.sh master stars      # one pass
```

A `<ref>` older than a pass (`burst`, `sun`) does not know it; seamcheck skips
that pass with a note and compares the rest.

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

Moving the goo and the tunnel onto `HSRenderer` -- their texture binding,
program and pipeline state now set by the backend, their geometry handed over
per surface and per strip -- compared at exactly 0 against the texture seam.
The passes run with shaders on, so the fixed-function looks a user gets with
shaders off were compared once by hand, with both trees' `parity` set to
`dShaders = 0`: exactly 0 again, on shots up to 96% (goo) and 84% (tunnel)
lit. Goo surfaces raised by 0.02 and tunnel strips wound the wrong way come out
DIFFERENT at 93.6% and 99.99%.

Moving the starburst onto `HSRenderer` -- its sphere drawn in the goo's look
through `beginGoo`, `drawGooSphere` and `endGoo`, tessellated by
`hsSphereBand` -- compared at exactly 0 on all four passes, the burst pass
included (which itself compares with itself at exactly 0), and at exactly 0 with
shaders off (by hand, as before; burst shots up to 94% lit). The sphere at 1.1
times its radius comes out DIFFERENT at 89.7%.

A first version drew the sphere's triangles as a list, through `impSurface`,
instead of as strips. The recorder accepts that path, and the burst pass passed
against `Goo.metal`; but the seam check measured worst lit>8 0.012%, past its
0.01% limit (lit>2 0.032%, inside its 0.1%): a few pixels whose cube-map
lookups land on the other side of a face edge. A master build changed only to
draw its display list as triangles differed from master by 0.171%, so the
topology alone does it. The sphere is therefore still drawn as strips from a
display list, which the recorder refuses: the burst pass has no Metal verdict
on it (ss-frm).

That slice was not a pure move in one case, found once the `sun` pass existed:
with shaders on and tunnels off, a starburst left GL_TEXTURE_2D off after its
sphere, and the sun drew as an untextured square for as long as the burst
lasted. `endGoo` now turns texturing back on, and the sun draws as it does on
every other frame. Measured by running `sun` set to goo on, shaders on and a
burst at frame 60 (480 frames, a shot every 30) on the commit before the slice
and after it: exactly 0 before the burst and after it ends (frame 420 on), and
up to 0.73% of lit pixels while it lasts, all within about 40 pixels of the
middle of the frame, where the sun is held.

## Backend check

`parity/backendcheck.sh` asks the question the passes lead up to: **does the
saver, drawn through the Metal backend, look like the saver drawn through GL?**
The passes replay GL's own recorded draws; this runs the saver's code through
`HSRendererMetal` (`Hyperspace/rendererMetal.mm`), which computes its own
matrices, fog and overlay projection and owns its textures, as the shipped port
will.

Two runs share the seed, so they draw the same frames: a plain run for its
`_gl.png`, and `renderer=metal`, which draws only through the backend and writes
`_backend.png`. `parity --compare-backend <pass>` judges them with that pass's
rules. In backend mode a shot that generates any GL primitive is an error, so a
draw that slipped past the backend cannot go unnoticed.

The backend draws everything the shaded saver draws: frames, fog, quads, the
overlay, the goo and starburst sphere, the offscreen target the caustics are
made in, and the tunnel. The shaders-off goo and tunnel are ss-5dl, and the
backend stops on them. Measured, worst shot:

| pass | lit>2 | lit>8 | bias | limits |
|---|---|---|---|---|
| `stars` | 0.000% | 0.000% | 0.004 | 1% / 0.1% / 0.06 |
| `goo` | 4.244% | 0.958% | 0.011 | 8% / 2.5% / 0.06 |
| `tunnel` | 0.738% | 0.163% | 0.015 | 3% / 0.6% / 0.06 |
| `burst` | 0.490% | 0.133% | 0.003 | 8% / 2.5% / 0.06 |
| `sun` | 0.021% | 0.000% | 0.004 | 1% / 0.1% / 0.06 |

Five of the twelve `stars` shots (2400 on) carry lens flares, 13 overlay quads
each, so the overlay is judged too. The `burst` shots from 90 to 240 carry the
starburst's sphere, which the replay could never judge (the recorder refuses a
display list drawn with a program): this is its verdict, GL against Metal, both
drawing it as the same 32 strips. `goo` comes out a little tighter than the
replay's 5.28% / 1.35% / 0.012, and `tunnel` well inside the replay's
1.50% / 0.28% / 0.012: the backend samples caustics it made itself, through
the same offscreen path GL used, where the replay sampled GL's.

Its kill cases are defects in the backend's C++ rather than its shaders:
`parity/defects/backend_<pass>_*.sed`, each a sed script over
`rendererMetal.mm`, built into its own `parity` with `build.sh --backend` and
required to FAIL. Killed: the model matrix before the camera, fog from the eye,
an overlay ignoring the aspect ratio, (SRC_ALPHA, ONE_MINUS_SRC_ALPHA) blending,
nearest sampling, the quad's color ignored; under `goo`, surfaces drawn at the
origin, the nebula and a normal map swapped, the fog scale as 1/end, and the
normal-map mix dropped; under `tunnel`, the caustic frames swapped, their mix
ignored (alpha 1), front faces culled, no culling, and the fog ending twice as
far; under `burst`, the sphere at radius 1 and half its bands; under `sun`,
`setFog(false)` ignored. A fixture that no longer changes the file is an error, not a survivor.

No pass reads a texture back, so `parity --backend-textures` checks uploads
directly: a 2D texture, 3- and 4-channel mip chains, and a cube of
six different faces, uploaded through `HSRendererGL` and `HSRendererMetal` and
read back level by level, face by face -- GL's by its own target names, so
neither side's face mapping is trusted. Measured: 49 levels and faces, every
byte the same. Its fixtures, `backend_textures_*.sed`, are killed: faces in
HSRenderer's order rather than Metal's (36 differ), RGB expanded with alpha 0
(42), and every level uploaded from level 0 (10). Sampling is the goo's to
judge, and one part of it is not separated: Metal filters a cube map across
face edges and Apple's GL does not. The goo passes with it, but the replay
samples on Metal too, so no measurement here isolates a seam.

`parity --backend-caustics` judges the offscreen target by what it is for: it
builds the tunnel's caustic textures, with the saver's own arguments (20 frames
at 256x256 from a 100x100 grid), once through each backend, and compares all
180 levels under the `stars` rule. Nothing random goes into them, so the only
difference is rasterization. Measured: worst 2 levels, 0.000% / 0.000% / bias
0.004. Its fixtures are killed: the readback not flipped to GL's bottom-up
order, strips at alpha 0.5, red and blue swapped, and a grey clear. GL's
`glReadBuffer(GL_BACK)` raises INVALID_OPERATION under parity's FBO, as in the
main loop; parity skips that one call while an FBO is bound, since read and
draw both stay on it, so any GL error at all fails the check.

One defect is not a fixture because it cannot show: dropping the map from GL's
clip z (-w..w) to Metal's (0..w). Without it Metal clips where GL's NDC z < 0,
which at the saver's near and far planes (0.001, 200) is within
2nf/(n+f) ≈ 0.002 units of the eye, nearer than anything Hyperspace draws; the
overlay sits at z = 0, on Metal's inclusive boundary. Measured: it passes
`stars` at 0.000%. It is still kept, since nothing guarantees the planes.

## Limits

- **One machine.** Calibrated on an Apple M5 Max under macOS 26. Another GPU or
  driver may move the residual; rerun the kill-check before trusting a verdict
  there.
- **Not in CI.** A hosted runner's GPU is virtualized and uncalibrated, so a
  verdict there would mean nothing yet. This runs locally.
- **The replay reuses GL's matrices.** A real port computes them itself, which
  can add a small error the passes do not measure. The backend check does, for
  the draws the backend has.
- **The replay never judges the starburst's sphere.** It is drawn with the goo
  program from a display list, which the recorder refuses, so the `burst`
  pass's replay verdict on those shots is always that refusal. The backend
  check judges it instead.
- **The passes compare; the backend renders.** The passes draw nothing of the
  saver's own; `HSRendererMetal` does.
