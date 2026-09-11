# Front-end epic — running checklist

The live to-do for the launcher / front-end flow. I own this file and keep it current as work
lands and as new requests come in. Design rationale and the real art paths live in
`docs/FRONTEND.md`; this is just the checklist. Newest dumps go under "Inbox" until triaged.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done (with the round/tag) · `[?]` needs a decision or data.

## 1. Connect / login screen
- [x] Reskin `Login.tscn` with the real `login_window.ddj` frame: ID / PW / Server / Connect / Exit (v0.1.103, round 150)
- [~] Backdrop behind it — pass 1 done (real `loading_login_01_2011.ddj` still); pass 2 = 3D flowing town camera
- [ ] Server dropdown / channel list (`login_chanel_window`), even if it is a single server for now
- [x] Keep every existing `NetClient` login/register wiring working (v0.1.103)
- [x] Plain-panel fallback when no Media.pk2 is present, so login always works (v0.1.103)
- [ ] "MaxiGuard verification success"-style status line area (cosmetic)

## 2. Loading screens
- [ ] Reusable loading overlay: `loading_<region>.ddj` + `gauge_loading.ddj` gauge + "NOW LOADING"
- [ ] Gold-dragon + class-silhouettes default screen (`loading_default.ddj`)
- [ ] Shown on every transition (login→select, select→customize, →world)
- [ ] Pick the region-appropriate loading image where known

## 3. Character select
- [x] Reskin `CharacterSelect.tscn`: list the account's characters (v0.1.104, round 151)
- [x] Stat panel: name, Level, real HP bar (v0.1.104) — MP / EXP / Stat are not tracked server-side, so honestly omitted, not faked
- [x] Buttons: Start, Delete, Create, Cancel (v0.1.104)
- [x] Extend the char-list protocol to carry gender/level/HP so the panel is real (v0.1.104)
- [ ] 3D character standing on the dock backdrop (pass 2)
- [ ] Full-bleed backdrop (Constantinople loading art is letterboxed; fine for now, 3D dock replaces it)
- [ ] Add MP / EXP / stat-point systems, then show them here
- [?] PIN / security — not in our data; omitted (screenshot shows Clear PIN, but we have no PIN system)

## 4. Character create — race / region select
- [?] **Deferred by design:** the server supports only the Chinese race (man/woman) — there are
  no European body assets — so a two-statue race pick would offer an uncreatable choice. Create
  goes straight to customize (Chinese) for now. Revisit if/when a European race is added.
- [ ] (If revisited) build from authored `resinfo\ifregionview.txt`: the two statues, tooltips, lizard

## 5. Character customize / create — **done** (v0.1.105, round 152)
- [x] Panel: Name + Sex (Man / Woman) — the two bodies the server supports
- [x] Live 3D character preview reflecting the sex choice, with the body's own idle animation
- [x] Confirm → creates the character (`NetClient.create_character`) and returns to select
- [x] Cancel → back to select
- [x] `Create` on the select screen opens this screen (temporary inline popup removed)
- [ ] Appearance sliders (figure/height/weapon/cloth) — omitted until there is a system behind them
- [ ] Unique-check button — no name-availability RPC yet; name is validated on create
- [ ] Dress the preview in the starting outfit (currently the bare base body)
- [ ] Rotatable / per-race backdrop polish (using the gold-dragon `loading_charactercustom` for now)

## 6. 3D backdrops (pass 2, the expensive one)
- [ ] Shared town backdrop streamed behind the screens (reuse the world loader)
- [ ] Slow flowing camera path through town
- [ ] Swap the pass-1 2D backdrops for it without touching the UI layer

## Tooling
- [x] `qa_shot.sh --scene <res://...>` to render an arbitrary front-end scene for verification (v0.1.103)

## Inbox (untriaged dumps)
- JellyBitz's SilkroadLauncher (https://github.com/JellyBitz/SilkroadLauncher) as the outer
  launcher reference — worth a look for the patcher/launch step distinct from the in-client flow.

## Notes / open questions
- Reference is "duckroad" (a private-server reskin): match the flow, not the exact branding.
- Everything here is our design except `ifregionview.txt`; disclose invented constants.
