# The front-end flow: launcher, login, character select, create, loading

The screens a player sees before the world: the launch/connect screen, character select,
race/region select, character customize, and the loading screens between them. This is the
Silkroad "duckroad" flow the project is recreating (the reference is a private server's reskin, so
the *flow* is faithful but the exact art and branding are not something to copy pixel-for-pixel).

## What is authored, and what is ours

The in-game HUD is built from the client's own `resinfo\if*.txt` layout DSL (see
`docs/HANDOFF_UI.md`). **The front-end is not.** Listing `Media.pk2` finds only these front-end
layouts in `resinfo`:

| File | What it is |
|---|---|
| `resinfo\ifregionview.txt` | the race/region select (the two statues on a map) — **authored** |
| `resinfo\pstitle.txt`, `pstitle_europe.txt` | the title/character-customize screen scaffolding |
| `resinfo\regionname.txt` | region name strings |

Everything else — the login window, the character-select stat panel, the customize sliders — the
retail client draws in hardcoded C++ against textures, with no layout file. So **those layouts are
our design**, grounded in the reference screenshots, and every constant we choose (a frame inset, a
slot position, a colour) is a disclosed choice, not a recovered value — the same standing rule as
the name plates and HP bars. Where a real texture exists we use it; where a number is invented we
say so.

## The real art (loaded at runtime from the player's own Media.pk2, never committed)

Found by `server/cmd/pk2list` against a real `Media.pk2`. Loaded exactly like the HUD art, through
`UiBuilder.load_texture("interface\\...ddj")` — which reads the `.ddj` out of the archive and
decodes it with `DdjReader`. Nothing here is extracted into the repo.

| Purpose | Path in `Media.pk2` |
|---|---|
| Login frame (Chinese/default) | `interface\outer\login_window.ddj` |
| Login frame (European) | `interface\outer\login_window_europe.ddj`, `..._europe_02.ddj` |
| Server channel window | `interface\outer\login_chanel_window_01.ddj`, `_02.ddj` |
| Login decoration / select | `interface\outer\login_deco_gradation.ddj`, `login_select.ddj` |
| Auto-login effect/frame | `interface\outer\auto_login_effect.ddj`, `auto_login_frame.ddj` |
| Login backdrop stills | `interface\loading\loading_login_01_2011.ddj` … `04` |
| Per-region loading art | `interface\loading\loading_constantinople.ddj`, `loading_china_1..4.ddj`, `loading_default.ddj`, `loading_charactercustom(_europe).ddj`, … |
| Loading progress gauge | `interface\loading\gauge_loading.ddj` |
| Character-custom / char-loading | `interface\loading\charactercustom.ddj`, `characterloading.ddj` |

## Plumbing already in place

- `Pk2Config.media_path()` → `Pk2Reader.open(path)` opens Media.pk2 (env `OPENSRO_MEDIA_PK2_PATH`
  or the `pk2` folder next to the executable).
- `UiBuilder.new(media_pk2, text_table)` with `load_texture` / `load_texture_region` / `media_archive`.
- `SkinnedBsrAssembler` builds a character from its `.bsr`; `paper_doll.gd` renders a skeleton into
  a `SubViewport` — the basis for the 3D character preview in select/customize.
- `NetClient` already carries the whole flow: login/register, `list_characters`,
  `create_character(name, gender)`, `delete_character`, `enter_world`.

## The flow and the plan (each step is independently shippable)

The UI layer is kept decoupled from the backdrop, so the 2D backdrop of the first pass can be
swapped for the 3D flowing-camera town of the later pass without touching the screens.

1. **Connect / login** — `login_window.ddj` frame with ID / PW / Server / Connect / Exit, over a
   backdrop. Preserves every `NetClient` wiring in `Login.gd`. *(started here)*
   **Round 679:** the logo clears the login box at every screen size (retail's own placement
   overlaps it on any screen taller than 837; `FrontEndFrame.logo_rect`), the fields' text is
   centred and the password shows `*` (both READ), and the server list is built: `setting/config.yaml`
   (`ClientConfig`, read by `YamlLite`) lists servers by name, the Server field shows the chosen one
   with retail's LIST button, and LIST opens retail's window 10 (`ServerListWindow`, from
   `pstitle.txt` and `server_window.ddj` / `server_select.ddj` / `server_rollover.ddj`) with each
   server's status (`ServerStatus`: Easy / Populated / Crowded / FULL / Check, READ thresholds and
   colours; "Closed" for no answer, ours). Everything recovered is in
   `docs/protocol/server_list.md`; the operator's side in deploy/README.md, "Configuring the
   client". (`login_chanel_window_01/02.ddj` and `login_select.ddj` are pstitle's *channel* window
   -- Section Channel / ChannelList, two UILM_STT_CHANNEL buttons -- not the server list; not
   built.)
2. **Loading overlay** — reusable: `loading_<region>.ddj` + `gauge_loading.ddj` + "NOW LOADING",
   shown on every scene transition.
3. **Character select** — the account's characters, a stat panel (name / HP / MP / EXP / level),
   Start / Delete / Create / Cancel, over a backdrop; 3D character preview in pass 2.
4. **Race / region select** — built from `ifregionview.txt`; the two statues, tooltips, the
   climbing lizard (pass 2 polish).
5. **Character customize** — Name + unique-check, Sex, Figure / Height / Volume / Weapon / Cloth
   sliders, a 3D preview, Confirm / Cancel.
6. **3D backdrops (pass 2)** — a town region streamed behind the screens with a slow flowing
   camera, reusing the world loader; the 3D character preview in select and customize.
   **Login done (round 678):** the title screen is retail's -- the intro script
   (`script\intro\*.txt`, option.txt's IntroName or the operator's choice) flown by
   `IntroCameraPath` over `FrontEndBackdrop` (World3D in `title_mode`), the letterbox frame and login
   window from `resinfo\pstitle.txt` (`FrontEndFrame`, Login.gd), the fades and the skip, the
   operator's theme (`FrontEndTheme`, `ThemeQuery`, server `-login-*`). Everything recovered is in
   `docs/protocol/intro_script.md`, including what character select, race select and create use;
   the next steps are in FRONTEND_CHECKLIST.md section 6.

## Verifying a front-end screen

`qa_shot.sh --scene res://scenes/Login.tscn` boots that scene instead of `World3D.tscn` under the
same xvfb + movie capture, with `OPENSRO_MEDIA_PK2_PATH` already exported, so the screen loads its
real art. No server is needed to render a screen (login only connects when Connect is pressed; the
boot-time theme query gives up at once on a refused connection).

The title since round 678: `OPENSRO_QA_TITLE_SEEK=0,12,26,40` stands the intro's camera at those
times, waits for the regions, and logs `QA TITLE SHOT t=.. frame ..` (then `QA LOGIN SHOT frame ..`
once the login window has faded in); `OPENSRO_QA_TITLE_SKIP_AT=<s>` clicks through at that many
seconds; `OPENSRO_QA_TITLE_HOUR=0..3` pins the random hour; `OPENSRO_LOGIN_INTRO=<name>` (and the
other `OPENSRO_LOGIN_*`) previews a theme. `client/tools/measure_login_ready.tscn` measures how long
the screen takes to become usable with a click at its first frame, and its longest frame;
`client/tools/check_intro_scripts.gd` checks every intro in an archive (counts, path accuracy, the
clamp, the regions).
