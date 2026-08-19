# PK2 container format (JMXVFS)

This describes the on-disk layout of `*.pk2` archives (internally "JMXVFS" — a JoyMax virtual
filesystem container), as long documented by the private-server / modding community across many
independent public tools and writeups over the past ~20 years. Nothing here comes from
disassembling a binary in this repo's history — it's a description of an on-disk container
format, the same category of knowledge as "how a ZIP central directory is laid out."

We implement a **read-only** parser: this project never writes or repacks pk2 archives, it only
opens ones a user already has.

## High-level shape

A `.pk2` file is a flat blob containing:

1. A fixed-size **header block** (256 bytes) at offset 0, containing a magic signature, version
   info, and a flag indicating whether the directory-entry table beyond the header is obfuscated.
2. A sequence of fixed-size **blocks**, each holding a fixed number of fixed-size **entries**
   (directory records). Each block is 128 bytes * (entries per block); entries describe either a
   subfolder, a file, or an "end of block" / "next block" marker forming a linked list of blocks
   per directory level.
3. Raw **file data**, referenced by entries via an absolute offset + length into the same blob.

## Header block (256 bytes)

| Offset | Size | Field                                            |
|-------:|-----:|---------------------------------------------------|
| 0x00   | 30   | Magic string, e.g. `"JoyMax File Manager!\0"` padded |
| 0x1E   | 4    | Version (uint32)                                  |
| 0x22   | 1    | Encryption flag (0 = entries not obfuscated, 1 = obfuscated) |
| 0x23   | 3    | Reserved                                          |
| 0x26   | 16   | Encryption checksum / verify blob (Blowfish-ECB of a fixed
plaintext, used to validate a key before trusting a table as decrypted) |
| ...    | ...  | Remainder reserved/unused                         |

Exact field widths vary slightly across client eras (this is a "best documented consensus", not
a spec from JoyMax); a robust reader should treat the header as "find magic, then locate the
first entry block right after the fixed header size" rather than hard-coding every byte.

## Directory entry (128 bytes each, packed into blocks of N entries)

| Offset | Size | Field                                                     |
|-------:|-----:|------------------------------------------------------------|
| 0x00   | 1    | Entry type: 0 = empty/unused, 1 = folder, 2 = file          |
| 0x01   | 81   | Name, null-terminated, ASCII/codepage (not UTF-8)           |
| 0x52   | 8    | Access/modify timestamps (FILETIME-ish, often unused/zero)  |
| 0x5A   | 4    | Position: for a folder, offset of its child block; for a file, offset of its data |
| 0x5E   | 4    | Size (file entries only)                                     |
| 0x62   | 8    | Next-block pointer (offset of the next block in this same directory listing, forms a linked list when a directory has more entries than fit in one block) |
| 0x6A   | 20   | Reserved                                                      |

Each block is a fixed count of these 128-byte entries back to back (commonly 20 entries/block =
2560 bytes, but treat the count as configurable rather than hardcoded). The first two entries of
the root/every directory block are conventionally `.` and `..` self/parent references, same idea
as a FAT/NTFS directory.

Walking the tree: start at the block immediately following the header, read entries until an
empty (type 0) entry or the block's next-block pointer is followed, recursing into folder
entries' child blocks.

## Obfuscation (Blowfish)

When the header's encryption flag is set, entry *bytes* (not file *contents* — the actual asset
data blobs are stored plain) are XOR/Blowfish-ECB obfuscated with a fixed default key that has
been public for the format's entire community lifetime: the ASCII bytes of the string
`169841` used as a Blowfish key, applied in ECB mode over 8-byte chunks of each directory entry
record (not the payload data section).

This is a fixed, long-published constant for interoperating with a community file-container
format — not a secret protecting first-party content; every actual asset byte (textures,
models, audio) in the data section is unencrypted once you've located it via the (optionally
obfuscated) directory table. We only implement Blowfish here because it's necessary to *read*
the directory table layout of a container format at all — same category of thing as needing to
implement DEFLATE to read a `.zip`.

## Implementation notes for our reader

- `server/internal/pk2` (Go): reference/tooling reader, used by any server-side dev tooling that
  needs to inspect a pk2 (e.g. validating a supplied Media.pk2 has the expected structure).
- `client/scripts/pk2` (GDScript): client-side reader used at runtime to stream assets out of a
  user-supplied pk2 without ever writing decrypted/extracted copies back to disk.
- Both are read-only. Neither reader nor any code in this repo re-encrypts or repacks pk2s.
