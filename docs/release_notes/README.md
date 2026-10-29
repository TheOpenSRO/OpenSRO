# Release notes

**Every release must have a changelog. This is a strict requirement:** the release build
(`.github/workflows/release.yml`) fails before building anything if `docs/release_notes/<tag>.md`
is missing, its title only repeats the version, or it lists no change
(`client/tools/release_notes.sh --check <tag>`).

These files are what players read in the game (Help > Release notes, made by
`client/tools/bundle_docs.sh`) and on the GitHub release page.

## Format

```
v0.1.603: one line saying what this release is about

- One line per player-facing change, in plain words.
- What a player can now do, see or no longer runs into -- not internal names.
```

## Cutting a release

1. Write `docs/release_notes/<tag>.md` covering every change since the last release.
2. `client/tools/release_notes.sh --check <tag>`.
3. Commit it (with the FEATURES bump), then the empty signed "Release <tag>" commit.
4. Tag with the same text: `git tag -s <tag> -F docs/release_notes/<tag>.md`.
5. Push the branch, then the tag.
