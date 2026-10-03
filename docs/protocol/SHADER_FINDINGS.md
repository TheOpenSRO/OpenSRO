# Client shader findings (`Data.pk2\Shader\`)

Found 2026-09-03 while surveying what real map/texture data in the archives this
project still doesn't use.

`Data.pk2` ships a `Shader\` folder of **76 files** holding the real client's own
Direct3D 8/9-era shaders — some as assembled `.vsh`/`.psh`, many as readable
`.c` source with comments intact. These are shipped client asset files, read the
same way as every other format in this project (see `LEGAL.md`); nothing is
copied into this repo, only the behaviour they describe is documented here.

## Terrain lighting equation

`Shader\terrainps14.psh` states it outright in its own header comment:

```
Surf_color  = (N.L) * terrain_tex * cloud_covering * self_shadow_term
Final_color = Surf_color * extinction + inscattering
```

Its three texture stages are named `TEX_NORMAL_HORIZON_MAP` (t0),
`TEX_TERRAIN_COLOR` (t1) and `TEX_CLOUD_LAYER` (t2). The shadow term is derived
from a horizon angle carried in the normal map's alpha, and the cloud layer
darkens the ground multiplicatively (`mul r0, r0, 1-r2`).

**Consequence for this project:** real terrain in the real client is darkened by
a *moving cloud layer* as well as by baked shadow. This project renders the
baked shadow (see `MAPT_FORMAT.md`) but has no cloud-shadow layer.

## Cloud layer projection

`Shader\scattervsdetail10.vsh`:

```
mad oT2.xy, r1.xz, c[CV_CLOUD_TEX_PROJECTION_0].xy, c[CV_CLOUD_TEX_PROJECTION_0].zw
```

where `r1` is the vertex transformed to world space. So the cloud shadow is a
plain **world-XZ planar projection**: `uv = world.xz * scale + offset`, with the
offset being what scrolls the clouds over the ground. Both scale and offset are
runtime constants the client computes; neither is a literal in the shader, so
neither is recoverable from the asset data alone.

## Distance haze is atmospheric scattering, not linear fog

> **Superseded for what the client draws (round 702).** The client's own landscape step
> (`Map::FUN_00a26f60`) sets up plain Direct3D LINEAR fog between the zone's channels 10 and 11
> times the view distance, for the terrain and the objects alike (`WorldFog`'s header has the
> addresses); the scattering shaders below ship in the archive but are not what it uses for the
> world's distance fog. `World3D.FOG_DENSITY` is gone; the fog is drawn at the READ planes.

The same vertex shader implements a full Rayleigh/Mie scattering model — named
constants `CV_BETA_1`, `CV_BETA_2`, `CV_BETA_DASH_1`, `CV_BETA_DASH_2`,
`CV_HG` (`= 1-g^2, 1+g, 2g, 0`, the Henyey-Greenstein phase term) — and computes
a per-channel extinction:

```
E = exp(-(beta_1 + beta_2) * s)      ; s = view-space distance
```

which `terrainps14.psh` then applies as `final = surf * E + inscattering`.

This is structurally the same operation as Godot's own exponential fog
(`1 - exp(-density * depth)` blending toward a fog color), which is what
`World3D._apply_real_environment_lighting` now uses, with the **real per-zone
`FogColor`** from `environment.ifo`.

**What is not recoverable:** the real `beta_1`/`beta_2` coefficients are runtime
shader constants. `environment.ifo`'s own two real scalar fog channels
(`CHANNEL_FOG_NEAR_PLANE` / `CHANNEL_FOG_FAR_PLANE`, named from the public
documentation) hold normalized values in **[-1, +1]** in every real record
checked — not world distances — so how they map onto real scattering
coefficients can't be derived from the assets. `World3D.FOG_DENSITY` is
therefore a disclosed rendering choice, flagged as such, not presented as real
data.

## Two-UV terrain

`Shader\vertexshader0lightmap.c` copies two separate UV pairs out of one
texcoord (`mov oT0.xy, v4.xy` / `mov oT1.xy, v4.zw`) — the terrain texture UV
and the lightmap UV. That matches what this project already does (per-quad
texture UV plus a whole-region lightmap on UV2).

## Height fog

`vertexshader0lightmap.c` also computes a second, separate fog term from the
vertex's height relative to a center Y (`VSC_HEIGHTFOG`), and combines it with
the distance fog by taking whichever is stronger (`min`) — the Korean comment on
that line says exactly that. Not implemented here; the constants behind it are
runtime values, same as the scattering coefficients.
