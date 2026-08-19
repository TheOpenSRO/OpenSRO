# Legal / IP Policy

This repo reimplements a Silkroad Online–style MMO. To keep it legitimate:

1. **No original assets in-repo.** No `.pk2`, textures, models, audio, or other Joymax/Gravity
   data files are ever committed here. Players/testers bring their own legally obtained
   `*.pk2` files; the client only knows how to *read* the container format at runtime.

2. **No decompiled/disassembled code.** Nobody pastes Ghidra decompiler output, IDA pseudocode,
   or binary-derived pseudocode into this repo, in commits, issues, or PRs. If reverse
   engineering happens elsewhere (on infrastructure the RE'er controls, against binaries they
   legally possess), only *facts derived from it* — e.g. "packet 0x7001 has this field layout",
   "pk2 header uses this blowfish key schedule" — are written up as plain descriptions in
   `docs/protocol/` and implemented independently. This is the standard clean-room technique:
   one side documents behavior, a different implementation writes original code against the
   documentation.

3. **Public protocol documentation is fair game.** Packet formats, pk2 container structure, and
   the historical Blowfish keys used by the original client have been publicly documented by the
   private-server community for close to two decades (forums, wikis, open-source private server
   projects). Treating well-established public knowledge as a spec to implement against is
   materially different from decompiling a binary in this repo's history.

4. **Trademarks/branding.** No Joymax/Gravity trademarks, logos, or "Silkroad Online" branding
   in released builds. Use a distinct project name for anything public-facing.

This is not legal advice — if this project is ever distributed publicly at scale, get an actual
IP lawyer to review before launch.
