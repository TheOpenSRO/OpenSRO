# Parties

What the engine enforces about parties. Implemented in `server/internal/party`.

Small system, and most of it was already recovered — this page collects it and
adds the one rule srrevamp was missing entirely.

## Size: two caps, selected by a flag

`FUN_00514560` is the join-time check, and there are **two** limits:

	5145cc  test BYTE PTR [ecx+0x10],0x1   ; bit 0 of the party's flags
	5145d0  je   clear
	5145d4  cmp  DWORD PTR [ecx+0x1c],0x8  ; set:   full at 8
	5145df  cmp  DWORD PTR [ecx+0x1c],edx  ; clear: full at 4  (edx = 4 at 5145af)

where `+0x1c` is the member count. The numbers alone would not say which limit
applies when; the errors do, because the client names them:

| flag bit 0 | cap | refusal |
|---|---|---|
| set | **8** | `UIIT_MSG_PARTYERR_MEMBER_FULL_EXP_SHARED_PARTY` |
| clear | **4** | `UIIT_MSG_PARTYERR_MEMBER_FULL_NONEEXP_SHARED_PARTY` |

So **bit 0 of the party's `+0x10` is the experience-sharing flag**, and an
exp-sharing party holds eight while a non-sharing one holds four.

srrevamp's parties share experience unconditionally — every member counts toward
`leveldata.PartyExpBonus` and no flag turns it off — so eight is the cap that
applies, and `MaxSizeNotShared` is recorded for completeness rather than use.

**A refusal that was correct is worth keeping.** An earlier pass found two loops
bounded at 8 near the party module and declined them, on the grounds that they
sat in `CMainProcess` functions calling `CGuild__BroadcastToLocalMember`, before
the `CParty` code begins — "far more likely a guild alliance's slot count than a
party's". The answer turned out to be 8 anyway. The refusal was still right: a
correct answer reached on wrong evidence is not a recovery, and the citation
above is from the join-time check itself.

## A party leader must be level 5

**Recovered 2026-09-17**, and srrevamp had no such rule.

Two call sites enforce it, both calling vtable slot 73 (`+0x124`, the level
getter) and comparing against the same literal:

	FUN_00513f90:  if (level < 5) return 0x2c0a;   // the plain create path
	FUN_00514170:  if (level < 5) return 0x2c0a;   // the party-match path

`0x2c0a` is `UIIT_MSG_PARTYERR_TOO_LOW_CREATOR_LEVEL`, which names the rule
rather than leaving it to be read off the comparison.

The party-match path applies it **only when the character is not already in a
party** — an existing member re-listing is checked for leadership instead
(`0x2c1d` `PARTYMATCH_RECORD_ERROR_PARTYLEADER`). So the rule is about *forming*
a party, not about being in one, which is what "CREATOR" in the error name says.

Level 5 is also the floor for using a COS summoner item
(`docs/protocol/pets.md`), so it reads as a general "past the tutorial" gate
rather than a party-specific number.

## Party matching

A separate subsystem with its own nine codes (`PARTYMATCH_*`), entered through
`FUN_00514170` and `FUN_00514010`. Beyond the creator level it enforces:

| check | refusal |
|---|---|
| a job item is worn | `0x2c26` `JOBITEM_WEAR_ERR_PARTYMATCH` |
| already listed | `0x2c24` `PARTYMATCH_JOIN_ERROR_DUPLE` |
| not the leader | `0x2c1d` `PARTYMATCH_RECORD_ERROR_PARTYLEADER` |

`PARTYMATCH_RECORD_ERROR_PARTYLEADER` is the single most widely returned party
code — it appears in nine different functions — so "only the leader may do this"
is the party system's dominant rule.

## Not recovered

- **Bit 2 of the party flags.** The attempt is recorded in
  `server/internal/party` so it is not repeated.
- **What the other party flag bits mean**, beyond bit 0.
- **The invite and expulsion flows.** Only the refusals are enumerated.
- **Whether the exp-sharing flag can change after creation.** Nothing read so
  far writes it.
