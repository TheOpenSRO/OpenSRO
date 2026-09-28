# DDJ texture format (JMXVDDJ)

`.ddj` is the client's texture container. It's the simplest of the `JMXV*` formats we've looked
at: a small, fixed 20-byte proprietary wrapper around an otherwise **completely standard,
unmodified Microsoft DDS file**. Confirmed empirically (byte-level, black-box) against three real
extracted `.ddj` files, the same way as the pk2 and bms fixes — no decompiler output is stored in
this repo, only the resulting facts about the container format. The embedded DDS layout itself is
Microsoft's own long-published public format ([DDS_HEADER / DDS_PIXELFORMAT on
learn.microsoft.com](https://learn.microsoft.com/en-us/windows/win32/direct3ddds/dds-header)), not
something reverse engineered from this game — only the 20-byte wrapper is proprietary.

## Wrapper (20 bytes)

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 12 | Magic, `"JMXVDDJ 1000"` |
| 0x0C | 4 | `uint32`, usually file size minus 12 (byte count of everything after the magic), but not reliably: a real sample (`Prim\Mtrl\Item\China\weapon\shield_90.ddj`, a 512x512 DXT3 texture with a full 10-level mip chain) has a value 256 bytes larger than the actual file despite an otherwise byte-exact, well-formed embedded DDS payload. Neither reader treats this field as a size check any more — it's parsed for informational purposes only. |
| 0x10 | 4 | `uint32`, observed constant `3` across every sample checked; meaning unconfirmed |
| 0x14 | ... | The embedded DDS file starts here, unmodified |

## Embedded DDS file (starting at offset 0x14)

Standard Microsoft DDS: 4-byte magic `"DDS "`, a 124-byte `DDS_HEADER` (confirmed via its own
`dwSize` field reading exactly 124 in every real sample checked), a 32-byte `DDS_PIXELFORMAT`
nested inside it at header offset 72, then raw pixel/mip data. Real samples checked included both
`DDPF_FOURCC`-compressed (DXT-family, confirmed present via strings in the client binaries:
`DXT1`/`DXT3`/`DXT5`) and plain `DDPF_RGB|DDPF_ALPHAPIXELS` uncompressed 32bpp textures — the
format is a genuine passthrough of whatever DDS variant the original art pipeline produced, not
narrowed to one compression mode.

Since this is just standard DDS, no further RE is needed to *read* it — any DDS-capable
image/texture library can load `data[20:]` directly once the wrapper is stripped.

## Implementation notes

- `server/internal/ddj` (Go): parses the wrapper and the embedded `DDS_HEADER`'s width, height,
  mip count and FourCC tag, and exposes the raw embedded DDS bytes (`Texture.DDS`) for handing off
  to an actual DDS decoder. Unit tested (`go test`) against a synthetic fixture (never real game
  data).
- No GDScript reader yet — like `.bms`, this is prep work for the eventual 3D rendering pass, not
  wired into the client. Godot 4 doesn't import raw DDS out of the box; actually displaying these
  textures will need either a small custom DXT/RGB decoder into a Godot `Image`, or converting
  `.ddj` → `.png`/`.ktx` offline as part of an asset pipeline — not yet decided.

## The runtime loader (READ, round 621's review follow-up)

`FUN_00b88420` → `FUN_00b87f20`, whose error string is "DDJCreateTextureHForMThread Error - %s":
- It opens the path it is handed through the archive object's vtable +0x2c, with no rewrite.
- It reads 12 bytes and checks "JMXV".
- It reads the u32 size field at 0x0c, then the rest.
- It passes the buffer from file offset 20, with size (size field − 8), to the statically
  linked D3DXGetImageInfoFromFileInMemory.
- By resource type, it creates a texture (D3DXCreateTextureFromFileInMemoryEx with the image's
  own width, height, MipLevels and format), a volume texture or a cube texture.

`FUN_00b8eb60`, cited in round 621, is a converter path the game does not run.

## FourCC 113 ('q'): D3DFMT_A16B16G16R16F (round 621)

- D3DX accepts a numeric D3DFORMAT in the FourCC slot. Four retail files store 113 there, the
  bytes `71 00 00 00`: D3DFMT_A16B16G16R16F, four 16-bit floats a pixel with R first in memory.
  They are `textures\ques1_monster_paper_q_2..5.ddj` in Particles.pk2, 128×128 with 8 declared
  mips (MEASURED).
- **Only the top level is clean** (every channel in 0..1). Level 1 of `_q_2` holds 15 non-zero
  values, down to −512, and every other stored mip of all four is zero (MEASURED, review
  follow-up). The retail loader uses the file's MipLevels, so retail minifies these to black or
  garbage.
- Each payload is twice its declared chain, and the size field is 256 bytes larger than the file.
- `DdjReader.to_image` reads the top level, clamps each channel to 0..1 and rounds it to 8 bits,
  and lets Godot build the mipmaps (OURS: clean mips, not retail's look when minified).
