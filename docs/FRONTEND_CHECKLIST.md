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
- [ ] Reskin `CharacterSelect.tscn`: list the account's characters
- [ ] Stat panel: name, HP/MP bars, EXP %, Stat points, Level
- [ ] Buttons: Start, Delete, Create, Cancel (+ Clear PIN placeholder)
- [ ] 3D character standing on the dock backdrop (pass 2)
- [?] PIN / security — likely not in our data; confirm and stub out

## 4. Character create — race / region select
- [ ] Build from authored `resinfo\ifregionview.txt`
- [ ] Two statues (European knight+horse / Chinese lion) on the map, click to pick race
- [ ] Hover tooltips describing each race
- [ ] The cute lizard that crawls up onto the box (polish)
- [ ] "Create" from select animates over to this screen

## 5. Character customize
- [ ] Panel: Name + Unique check, Sex (Male/Female), Figure / Height / Volume / Weapon / Cloth sliders
- [ ] 3D character preview reflecting the choices, rotatable
- [ ] Per-race backdrop (European town vs Chinese Jangan), differs by race picked
- [ ] Confirm → creates the character (`NetClient.create_character`) and returns to select
- [ ] Cancel → back to race select

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
