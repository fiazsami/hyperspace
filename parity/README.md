# GL → Metal parity

`parity` answers one question for the Metal port: **does the saver, drawn
through the Metal backend, look like the saver drawn through OpenGL?** It runs
Hyperspace's code offscreen, deterministically, once through `HSRendererGL` and
once through `HSRendererMetal` (`Hyperspace/rendererMetal.mm`), and compares
the two images shot by shot. There are no stored golden images: both sides
render the same frame in the same process, so the reference is always the
shipped renderer on this machine.

```bash
parity/build.sh                                                    # -> .parity-build/parity
.parity-build/parity goo metal .parity-build/out/gl                # NNNNN_gl.png
.parity-build/parity goo metal .parity-build/out/mt renderer=metal # NNNNN_backend.png
.parity-build/parity --compare-backend goo .parity-build/out/gl .parity-build/out/mt
parity/backendcheck.sh                                             # every pass and fixture (~7.5 min)
parity/seamcheck.sh master                                         # GL against GL at <ref>
```

Until ss-a4a.4.5 the passes were judged a second way: a recorder interposed
on GL, captured every draw with the state behind it, and replayed them through
`metal/`'s shaders. That replay is retired. It existed to translate the shaders
before there was a backend to draw them; the backend now draws everything the
shaded saver draws, and its shader fixtures run there (below). Its measurements
below are kept, marked as the replay's, because the limits were fixed from
them.

## Passes

| pass | what is judged | shader | run |
|---|---|---|---|
| `stars` | stars and lens flares; the sun is never in frame (below) | `metal/FixedFunction.metal` | 60 s, 12 shots |
| `goo` | the goo: cube-mapped normals, reflection, Fresnel | `metal/Goo.metal` | 60 s, 12 shots |
| `tunnel` | the tunnel: two caustic textures, two octaves | `metal/Tunnel.metal` | 2 min, 36 shots |
| `burst` | the starburst's sphere, then the goo | `metal/Goo.metal` | 8 s, 16 shots |
| `sun` | `stars`, with the sun held in view | `metal/FixedFunction.metal` | 20 s, 12 shots |
| `goosoft` | `goo` with the backend's goo soft, as the saver draws it, judged on 16×16 block means (below) | `metal/Soften.metal` | 60 s, 12 shots |

Stars draw in every pass, through `FixedFunction.metal`. The tunnel needs two
minutes because one rarely puts the camera inside a tunnel; most shots of the
first minute are under 1% lit. Every pass runs with shaders on. The Metal saver
draws the shaded look only (ss-5dl), and `renderer=metal` refuses the
shaders-off goo and tunnel with exit 2.

The saver sets off its first starburst after five minutes. `burst` sets one off
itself, at frame 60, ahead of the camera along the path as the saver does, but
at fixed values where the saver draws random ones: 0.75 of the depth ahead
(the saver: 0.5 to 1.0) and height 0 (the saver: -1 to 1). It is placed from
the previous frame's camera; the saver uses the current one. Goo is on, as the
saver's default is, because the sphere draws with the goo's program and
textures. A burst that fails to start is an error, not a pass. The shots up to
about frame 420 carry the sphere; the later ones judge the goo, with the goo
pass's limits throughout.

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

A pass that drew nothing in any shot is an error rather than a pass, and so is
a GL error in a GL shot. In backend mode "nothing" is counted on the pass's own
surface: a `goo` or `burst` run with no goo surface drawn, or a `tunnel` run with
no tunnel strip, is an error, since the stars alone would still compare.
A shot outside the rule writes `NNNNN_diffx8.png` (per-pixel difference ×8)
beside the new run's images; it is the first thing to look at when a pass
fails. In `renderer=metal` a shot in which GL generated any
primitive (`GL_PRIMITIVES_GENERATED`) is an error: a draw that slipped past the
backend into GL cannot go unnoticed. Rates are over lit pixels, not the frame.
Star frames are 0.3–4% lit, and a per-frame rate diluted every defect below 1%.

The limits were fixed by the replay, from a faithful translation and from
defects, **before** any candidate shader was scored:

| pass | max2 | max8 | replay: correct translation, worst shot | replay: weakest defect, worst shot |
|---|---|---|---|---|
| `stars` | 1.0% | 0.1% | 0.00% / 0.00% / bias 0.003 | fog scale ×1.1: 14.14% / 4.17% / bias 0.998 |
| `goo` | 8.0% | 2.5% | 5.28% / 1.35% / bias 0.012 | fog scale ×1.1: 9.65% / 3.05% / bias 0.357 |
| `tunnel` | 3.0% | 0.6% | 1.50% / 0.28% / bias 0.012 | radial fog: 4.81% / 0.28% / bias 0.197 |

`goosoft` came later, with the soft goo (ss-5j5), and was fixed the same way,
at resolution 20, before the fixtures were written. Softening moves light a
few pixels, so pixel by pixel the soft goo differs from GL's sharp goo almost
everywhere it is lit. `goosoft` therefore compares both images after averaging
each over 16×16 blocks: those absorb most of the blur, while goo drawn in the
wrong place still shows. Worst shot, block means:

| | lit>2 | lit>8 | bias |
|---|---|---|---|
| faithful | 34.2% | 4.48% | 0.665 |
| drawn two pixels left (`goosoft_shift2`) | 62.9% | 25.5% | 0.801 |
| upside down (`goosoft_flip`) | 98.6% | 96.3% | 0.586 |
| tent divided by 15, ~7% too bright (`goosoft_tent15`) | 84.9% | 42.7% | 7.231 |
| never added back (`backend_goosoft_nocomposite`) | 99.96% | 99.7% | 121.6 |
| limits | 50% | 12% | 2.0 |

The flip and the shift are why the blocks are there: an earlier version judged
the signed bias alone, and both passed it, the flip scoring better than the
faithful build. Smaller blocks separate less (at 8×8 the faithful build's
lit>8 is 14.1% against the four-pixel shift's 50.6%). What `goosoft` still
cannot see: whether the goo is soft at all. A soft goo drawn sharp passes, and
the look itself was chosen by eye, from the bake-off.

`backendcheck.sh` re-proves the separation on every run. Loosening a limit to
let a change through defeats the instrument; if a correct change fails, find
out why first.

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
- Mip chains are built on the CPU (`hsBuildMipmaps`) and uploaded level by
  level through each backend, so mip generation is the same on both sides;
  `--backend-textures` checks that the uploads agree byte for byte.

Two runs of the same pass produce identical output.

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
instead of as strips. The recorder accepted that path, and the burst pass passed
against `Goo.metal`; but the seam check measured worst lit>8 0.012%, past its
0.01% limit (lit>2 0.032%, inside its 0.1%): a few pixels whose cube-map
lookups land on the other side of a face edge. A master build changed only to
draw its display list as triangles differed from master by 0.171%, so the
topology alone does it. The sphere is therefore still drawn as strips, and
the backend check judges it (below).

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

`parity/backendcheck.sh` runs every pass both ways and judges it with
`--compare-backend`. `HSRendererMetal` computes its own matrices, fog and
overlay projection and owns its textures, as the shipped saver does.

The backend draws everything the shaded saver draws: frames, fog, quads, the
overlay, the goo and starburst sphere, the offscreen target the caustics are
made in, and the tunnel. The shaders-off goo and tunnel are ss-5dl, and the
backend stops on them. Measured, worst shot:

| pass | lit>2 | lit>8 | bias | limits |
|---|---|---|---|---|
| `stars` | 0.000% | 0.000% | 0.001 | 1% / 0.1% / 0.06 |
| `goo` | 4.139% | 0.849% | 0.023 | 8% / 2.5% / 0.06 |
| `tunnel` | 0.107% | 0.028% | 0.002 | 3% / 0.6% / 0.06 |
| `burst` | 0.816% | 0.170% | 0.006 | 8% / 2.5% / 0.06 |
| `sun` | 0.000% | 0.000% | 0.002 | 1% / 0.1% / 0.06 |
| `goosoft` | 34.189% | 4.480% | 0.665 | 50% / 12% / 2.0, on 16×16 block means |

At the default goo resolution of 20, since ss-5j5 raised it from 10. At 10,
measured when the goo's surface moved to the GPU, `goo` was 4.611% / 1.121% /
0.015 and `burst` 0.906% / 0.201% / 0.006; the others come out the same.

Earlier, re-measured 2026-11-16 on an M5 Max, when the goo's surface moved to the GPU.
`tunnel`, `burst`, `stars` and `sun` come out the same on the commit before
that change; the earlier figures here were older. `goo` was 3.011% / 0.674% /
0.011 before it. The two runs no longer draw the same triangles: the kernel
evaluates the field with a precise cos where the CPU reads rsCosf's table, and
draws each cell's triangles unshared, in another order. Which of those the
1.6 points come from was not measured.

Five of the twelve `stars` shots (2400 on) carry lens flares, 13 overlay quads
each, so the overlay is judged too. The `burst` shots from 90 to 240 carry the
starburst's sphere, which the replay could never judge (its recorder refused a
display list drawn with a program): this is its verdict, GL against Metal, both
drawing it as the same 32 strips. `goo` comes out a little tighter than the
replay's 5.28% / 1.35% / 0.012, and `tunnel` well inside the replay's
1.50% / 0.28% / 0.012: the backend samples caustics it made itself, through
the same offscreen path GL used, where the replay sampled GL's.

### Fixtures

Two kinds, and every one must FAIL its pass. A fixture that no longer changes
what it targets is an error, not a survivor.

**Shaders.** `parity/defects/<pass>_<defect>.metal` is the pass's shader file
with one deliberate translation defect: constants carried over from the other
shader, swapped or flipped texture coordinates, radial instead of planar fog, a
dropped term. backendcheck copies `metal/`, puts the fixture in place of
`FixedFunction.metal`, `Goo.metal` or `Tunnel.metal`, and draws the pass
through the committed backend from that copy. Line 1 of each fixture records the
git blob of the shader it was made from (`base=`); one whose base is not the
shader as it stands is reported STALE, since it would differ by the change as
well as by its defect. `burst` draws with `Goo.metal` but has no shader
fixtures of its own: its sphere and goo share the goo's shader, which the `goo`
fixtures cover. `sun` judges with the `stars`
pass's shader, and its one fixture is the defect only it can see:
`sun_fogalways` fogs every draw, the sun's included. The only other draws with
fog off are the lens flares, in the overlay plane at eye depth 0, where fog
changes nothing -- so under `stars` that fixture passes. When a shader in
`metal/` changes, regenerate the fixtures from the new text, with the new
`base=`, rather than editing the rule. These fixtures were written for the replay and now run here; all 29
are killed. The
narrowest by lit>2 are `tunnel_fog110` (3.72% against 3%) and
`tunnel_radialfog` (4.28%), and both are far outside on bias (0.219 and 0.200
against 0.06); `sun_fogalways` is inside lit>2 at 0.75% and killed by its bias,
0.843.

**The goo's build kernel.** The backend builds the goo's surface on the GPU
(`metal/GooBuild.metal`), so the CPU's `impCubeVolume` no longer stands between
the two runs: GL draws the surface the CPU built, Metal the one the kernel
built, and the `goo` pass judges the kernel as much as the shader.
`parity/defects/goobuild_<defect>.metal` is that kernel with one defect, made
and checked like the shader fixtures (`base=` is `GooBuild.metal`'s blob), and
run under `goo`. Killed: each vertex at its edge's midpoint, each vertex taking
its edge's first corner's normal unmixed, the normal's neighbour half a
cell along instead of one, and two edges swapped in the kernel's own edge
table, which the unit tests cannot see. The kernel's first cut used the field's exact
gradient for normals, and this pass failed it at 98% lit>2 -- the reflections
moved across the whole surface -- which is why it copies impCubeVolume's
forward differences instead.

**The soft goo.** `goosoft_tent15.metal` is `Soften.metal` with the tent
divided by 15, `goosoft_flip.metal` adds the goo upside down, and
`goosoft_shift2.metal` two pixels to the left; `backend_goosoft_nocomposite.sed`
draws the soft goo into its target and never adds it back. All four are killed
under `goosoft`.

**Backend C++.** `parity/defects/backend_<pass>_*.sed`, each a sed script over
`rendererMetal.mm`, built into its own `parity` with `build.sh --backend` and
required to FAIL. Killed: the model matrix before the camera, fog from the eye,
an overlay ignoring the aspect ratio, (SRC_ALPHA, ONE_MINUS_SRC_ALPHA) blending,
nearest sampling, the quad's color ignored; under `goo`, the GPU-built surface
drawn at the origin, its blocks' cells starting a whole block from their
centres, the nebula and a normal map swapped, the fog scale as 1/end, and the
normal-map mix dropped; under `tunnel`, the caustic frames swapped, their mix
ignored (alpha 1), front faces culled, no culling, the fog ending twice as
far, the fog scale as 1/end, and the camera left out of its projection; under `burst`, the sphere at radius 1 and half its bands; under `sun`,
`setFog(false)` ignored.

No pass reads a texture back, so `parity --backend-textures` checks uploads
directly: a 2D texture, 3- and 4-channel mip chains, and a cube of
six different faces, uploaded through `HSRendererGL` and `HSRendererMetal` and
read back level by level, face by face -- GL's by its own target names, so
neither side's face mapping is trusted. Measured: 49 levels and faces, every
byte the same. Its fixtures, `backend_textures_*.sed`, are killed: faces in
HSRenderer's order rather than Metal's (36 differ), RGB expanded with alpha 0
(42), and every level uploaded from level 0 (10). Sampling is the goo's to
judge, and one part of it is not separated: Metal filters a cube map across
face edges and Apple's GL does not. The goo passes with it, and no
measurement here isolates a seam.

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
  driver may move the residual; rerun `backendcheck.sh`, fixtures and all,
  before trusting a verdict there.
- **Not in CI.** A hosted runner's GPU is virtualized and uncalibrated, so a
  verdict there would mean nothing yet. This runs locally.
- **Shaders on only.** The Metal saver has no shaders-off look (ss-5dl), so
  nothing compares GL's fixed-function goo and tunnel with anything.
- **The shaded GL saver is the reference.** A deliberate visual change to the
  Metal side will fail these passes by design; that is the point at which the
  reference has to change, not the limits.
