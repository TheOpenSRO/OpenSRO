# PK2 container format (JMXVFS)

This describes the on-disk layout of `*.pk2` archives (internally "JMXVFS" — a JoyMax virtual
filesystem container). We implement a **read-only** parser: this project never writes or repacks
pk2 archives, it only opens ones a user already has.

An earlier version of this doc was based on the format as long-described by the private-server /
modding community. That description turned out to be wrong in several concrete ways — a real
archive's directory table decrypted to garbage under it, and the (incorrectly understood) "next
block" chain-following logic sent the reader into an infinite loop on a real `Media.pk2`. The
layout and obfuscation scheme below were instead re-derived empirically: byte-for-byte, black-box,
against a real archive, until decrypted directory entries produced real, sane file and folder
names. No decompiler output is stored anywhere in this repo or its history — only the resulting
facts about the container format, the same category of knowledge as "how a ZIP central directory
is laid out."

## High-level shape

A `.pk2` file is a flat blob containing:

1. A fixed-size **header block** (256 bytes) at offset 0, containing a magic signature, version
   info, and a flag indicating whether the directory-entry table beyond the header is obfuscated.
2. A sequence of fixed-size **blocks**, each holding a fixed number of fixed-size **entries**
   (directory records). Each block is 128 bytes * (entries per block), holding a directory's
   entries — including the conventional `.` and `..` self/parent entries.
3. Raw **file data**, referenced by entries via an absolute offset + length into the same blob.

## Header block (256 bytes)

| Offset | Size | Field                                            |
|-------:|-----:|---------------------------------------------------|
| 0x00   | 30   | Magic string, `"JoyMax File Manager!\n"` padded with NULs |
| 0x1E   | 4    | Version (uint32 LE); observed value `0x01000002`   |
| 0x22   | 1    | Encryption flag (0 = entries not obfuscated, 1 = obfuscated) |
| 0x23   | 16   | Blowfish-encrypted checksum blob (see below); only its first 3 bytes are actually checked by the reference client |
| ...    | ...  | Remainder unused/reserved                          |

## Directory entry (128 bytes each, packed into blocks of `ENTRIES_PER_BLOCK` = 20)

| Offset | Size | Field                                                     |
|-------:|-----:|------------------------------------------------------------|
| 0x00   | 1    | Entry type: 0 = empty/unused, 1 = folder, 2 = file          |
| 0x01   | 89   | Name, NUL-terminated, ASCII/codepage (not UTF-8). Reused slots can carry stale bytes *after* a still-valid terminator — always cut at the first NUL, never just trim trailing NULs |
| 0x5A   | 8    | FILETIME-shaped timestamp (access/create); unused by our reader |
| 0x62   | 8    | FILETIME-shaped timestamp (modify); unused by our reader   |
| 0x6A   | 4    | Position (uint32 LE): for a folder, the byte offset of its own entry block; for a file, the byte offset of its data |
| 0x6E   | 4    | Reserved/unused (observed as always 0)                      |
| 0x72   | 4    | Size (uint32 LE): file size in bytes; 0 for folders          |
| 0x76   | 10   | Reserved/unused                                              |

Each block is `ENTRIES_PER_BLOCK` (20) of these 128-byte entries back to back (2560 bytes/block).
**No "next block" chain-continuation mechanism was found** for a directory with more than 20
entries — every real folder inspected fit in one block. If a real archive ever turns out to need
more than one block per directory, that's a real gap to close, but do it with a cycle/bound guard;
the previous (wrong) implementation of a "next block" field caused an infinite loop by chasing a
garbage offset through a misidentified field.

Walking the tree: read one block at the folder's offset (root folder starts right after the
header), and for each entry with type 1 or 2 whose name isn't `.` or `..`, record it — folders
recurse via their `Position` field, files are read via `Position`+`Size`.

## Obfuscation (Blowfish, with two client-specific quirks)

When the header's encryption flag is set, entry *bytes* (not file *contents* — the actual asset
data blobs in the data section are stored plain) are obfuscated with standard Blowfish (P-array
and S-boxes using the textbook pi-digit constants), but with two deviations from a naive
"Blowfish-ECB with a raw key" implementation, both verified against a real archive:

1. **Key obfuscation.** Before running the key through Blowfish's standard key schedule, each byte
   of the raw key string (the well-known default key `169841`) is XORed against a fixed,
   format-constant byte table. Only the bytes up to the key's length matter (the table is zero
   beyond what a 6-byte key needs); this is a fixed constant needed purely to interoperate with
   the container format, not a secret protecting first-party content.
2. **Word-swapped blocks.** Each 8-byte block is not fed to Blowfish as a plain big-endian byte
   stream. Each 4-byte half is byte-order-reversed before the standard Blowfish block
   encrypt/decrypt, and reversed back afterward — equivalent to treating each half as a
   little-endian 32-bit word rather than the conventional big-endian one.

Both quirks were confirmed by reproducing the header's own checksum blob (offset 0x23): encrypting
the fixed plaintext `"Joymax Pak File\0"` with the archive's effective (XOR'd) key, using the
word-swap convention, reproduces the real bytes stored in a real archive's header.

## Implementation notes for our reader

- `server/internal/pk2` (Go): reference/tooling reader, used by any server-side dev tooling that
  needs to inspect a pk2 (e.g. validating a supplied Media.pk2 has the expected structure).
- `client/scripts/pk2` (GDScript): client-side reader used at runtime to stream assets out of a
  user-supplied pk2 without ever writing decrypted/extracted copies back to disk.
- Both are read-only. Neither reader nor any code in this repo re-encrypts or repacks pk2s.
- Both implementations are kept independently in sync against this doc; the Go one is unit
  tested (`go test`), the GDScript one has a headless test suite
  (`godot --headless --script res://scripts/pk2/pk2_reader_test.gd`, wired into CI). The generic
  Blowfish block cipher itself stays a plain, standard implementation in both languages
  (`blowfish.gd` / `golang.org/x/crypto/blowfish`) — the two pk2-specific quirks above (key XOR
  table, word-swapped blocks) live in the pk2 reader layer, not in the cipher.
