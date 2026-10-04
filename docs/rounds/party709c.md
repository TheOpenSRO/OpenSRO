## Seven-hundred-and-ninth round, lane party709c: the party GUI read from the client -- the party window, the settings dialog, party matching, the join popup and progress bar, and the HUD member boxes, with their rules from the exe and their art measured

Spec only; no code changed. The full record is `docs/protocol/party_gui.md`. Sources:
- `sro_client.exe`, its decompile and objdump;
- the Media archive's `resinfo` layouts, `interface\party\`, `interface\quickparty\` and
  `textuisystem.txt`;
- the user's twelve screenshots of the original (`/root/opensro-handoff/party_refs/`).

**What was read (READ unless marked):**

- **Party window** (`CIFParty`, `ifparty.txt`, `0x6d6fc0`/`0x6d6640`/`0x6d6d00`):
  - the leader row and the seven `CIFPartySlot` rows;
  - the caption "Party informaiton (Invitation of party member available)", which is
    `UIIT_STT_PARTY_INFO` + " (" + `_JOIN_ANYONE` + ")" only while "anyone may invite" is set;
  - the type line, bright in a party and greyed out of one;
  - Dismiss for the leader only;
  - Banish on every row for a leader, Leave on the player's own row otherwise;
  - Invite needs a selected target and sends create-and-invite (out of a party) or invite;
  - **Set opens only when not in a party**: its values are client-side preferences that the
    create request carries as `exp | item<<1 | anyone<<2`.
- **The party manager's state** at `0xeeebd8+0x20`: exp, item, anyone, a `*name` flag, I-am-leader,
  in-party, count, leader JID, my JID; the 4/8 full test.
- **Settings dialog** (`CIFSetPartyMode`): radio item 0 = Share, item 1 = Free-For-All; the
  check box is party flag bit 2; Yes stores locally and sends nothing.
- **Party matching** (`CIFPartyMatch`):
  - the purpose order is Hunting, Quest, Trade, Thief, All. The purpose byte 0..3 uses the same
    order;
  - **Race and Purpose are text in this exe** ("CHN"/"EUR"; purpose names), not the icons in the
    user's screenshots;
  - the Type icon is `pt_association.ddj` (8, exp-sharing) or `pt_eachone.ddj` (4);
  - the player's own listing is pinned to the top in (135,233,255);
  - the selected row takes `com_bar01select_`, MEASURED as a (255,178,82) gold line;
  - the button enable rules;
  - Search is a client-side, exact whole-name filter over held records;
  - Refresh has a 2 s cooldown; the page spin requests pages;
  - the register and auto-match objectives are restricted by the player's job (Trader/Hunter →
    Trade only, Thief → Thief only, none → Hunting/Quest);
  - **Join party does no client-side level or job check**: the refusal is the server's.
- **Leader popup** (`CIFPartyMatchReqJoin`): the two mastery icons, level, CHN/EUR from the model,
  region name, guild; Confirm sends 1, Cancel 0, and **10 s without an answer sends 2**.
- **Join progress** (`CIFPartyJoinProgress`): the "[me]You [leader] has requested…" text, a gold
  bar filled over **10 s** in 200 ms ticks.
- **Refusals** go to the bottom-right system message window, type 4.
- **HUD boxes** (`CIFQuickPartyWnd`/`Slot`):
  - at 4,137, slots built in code (`ifquickpartywnd.txt` is dead), stepping 73 px with the buff
    option on and 56 without;
  - the red leader flag, the 3D portrait (64x64), and two 17x17 mastery icons from the member
    record;
  - **the blue overlay is stepped, not continuous, and only in an exp-sharing party**: five
    textures (_60.._100, MEASURED (14,96,255) at α 130/158/181/211/241) at 3D distances ≥ 600,
    700, 800, 900 and 1000;
  - buffs show only while the member is spawned in the client;
  - the selected member's slot shows `qpt_grope_select.ddj`, MEASURED teal/cyan, following the
    world target;
  - selecting yourself shows the PMI's `pmi_select.ddj`, MEASURED yellow;
  - the lock and drag reorder appear above two members.

**Corrections filed in the spec's table:**
- the party rows are more than name/level/HP;
- the race mark comes from the model id, not a race field;
- two dead layouts;
- the matching list's icons vs this exe's text;
- this exe's 110 default level against the screenshots' 100.

**OPEN (blocking):**
- icons or text in the matching list (the user's call);
- the job byte's wire value 4;
- the member record's wire fields;
- the join popup's second id and kind byte;
- member byte `+0x58`.

No renders, no perf gate (docs only).
