# pk2 reader

Read-only pk2 (JMXVFS) container reader, implemented against
[`docs/protocol/PK2_FORMAT.md`](../../../docs/protocol/PK2_FORMAT.md).

- `pk2_reader.gd` — `Pk2Reader`: header parsing, directory tree walk (including multi-block
  chains), file extraction. Mirrors `server/internal/pk2` in Go; keep both in sync.
- `blowfish.gd` — `Blowfish`: minimal Blowfish-ECB cipher needed to de-obfuscate encrypted
  directory tables. Decrypt-only.
- `blowfish_constants.gd` — standard Blowfish P-array/S-box init constants.
- `blowfish_test.gd`, `pk2_reader_test.gd` — headless test scripts, run via
  `godot --headless --path client --script res://scripts/pk2/<name>.gd` (wired into CI).

Read-only: this project never writes or repacks pk2 archives.
