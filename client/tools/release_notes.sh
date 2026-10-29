#!/usr/bin/env bash
# Prints one release's changelog as Markdown: its title line, a blank line and
# the bullet list of player-facing changes.
#
# The source of truth is docs/release_notes/<tag>.md, written and committed
# BEFORE the tag is cut (docs/release_notes/README.md). Older releases that
# predate those files fall back to the tag's own message (subject + body; the
# body leaves out the signature, which %(contents) would print).
#
#   release_notes.sh v0.1.603          the notes
#   release_notes.sh --check v0.1.603  exit 1 unless the notes file exists, its
#                                      title says more than the version and it
#                                      lists at least one change
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check=0
if [ "${1:-}" = "--check" ]; then check=1; shift; fi
tag="${1:?usage: release_notes.sh [--check] <tag>}"
file="$repo_root/docs/release_notes/$tag.md"

if [ "$check" = 1 ]; then
  fail() { echo "release notes for $tag: $*" >&2; echo "Write docs/release_notes/$tag.md (see docs/release_notes/README.md) and commit it before tagging." >&2; exit 1; }
  [ -f "$file" ] || fail "docs/release_notes/$tag.md is missing"
  title="$(head -n1 "$file" | sed -e 's/[[:space:]]*$//')"
  rest="${title#"$tag"}"; rest="${rest#:}"; rest="$(echo "$rest" | sed -e 's/^[[:space:]]*//')"
  [ -n "$rest" ] || fail "the title line must say what changed, not only \"$tag\""
  grep -qE '^- [^[:space:]]' "$file" || fail "no change listed (one '- ' line per change)"
  echo "release notes for $tag: ok ($(grep -cE '^- ' "$file") changes)"
  exit 0
fi

if [ -f "$file" ]; then
  sed -e 's/[[:space:]]*$//' "$file"
else
  git -C "$repo_root" tag -l --format='%(contents:subject)' "$tag"
  body="$(git -C "$repo_root" tag -l --format='%(contents:body)' "$tag" | sed -e 's/[[:space:]]*$//' | awk 'NF{p=1} p')"
  if [ -n "$body" ]; then echo; printf '%s\n' "$body"; fi
fi
