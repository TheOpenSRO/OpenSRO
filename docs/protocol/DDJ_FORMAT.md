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
| 0x0C | 4 | `uint32`: file size minus 12 (i.e. byte count of everything after the magic) |
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
