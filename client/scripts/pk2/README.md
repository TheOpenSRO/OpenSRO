# pk2 reader

Placeholder for a from-scratch pk2 container reader (JMXVFS format), implemented against
publicly documented format notes in `docs/protocol/PK2_FORMAT.md` (not yet written). Will
support: header parsing, directory tree walk, per-entry Blowfish-based obfuscation handling,
streaming file extraction. Read-only — this project never writes/repacks pk2 archives.
