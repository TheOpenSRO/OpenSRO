# What the string-based naming levers can still reach

This project has used four levers that name a function from text in the binary:

| lever | what it gave |
|---|---|
| `## Illegal ##` virtual stubs | 209 `IGObj` vtable slots |
| those slots applied to implementations | 275 addresses, **271 already named** |
| server log calls passing their own name | 108 functions, **104 already named** |
| client asserts (file, line, expression) | 123 source files, 5,235 attributions |

Three of the four are **exhausted**, which is worth stating plainly so the next
pass does not re-run them expecting yield:

- Vtable slots to implementations: 4 functions left, all `IGOBJ::` spelling
  variants of names already known.
- Server self-naming literals: 4 left, and 3 of those look like RTTI type tags
  (`AI::CMsg`, `AI::CSquad`) rather than methods, so they are **not applied**.

## The control that proves the lever was applied correctly

Of the 108 server functions that log a `Class::Method` literal, 104 already carry
a name — and in **104 of 104** the literal matches that name. The literal really
is the function's own identity, and a previous pass really did apply it.

## The ceiling

Of **26,727** unnamed server functions, only **5,971 (22.3%)** contain any string
literal at all. The other **20,756 cannot be reached by any text-based lever**,
because there is no text in them.

Size tells the same story:

| size | with a string | without |
|---|---|---|
| < 32 B | 9 | 1,902 |
| < 128 B | 3,361 | 11,506 |
| < 512 B | 2,000 | 6,670 |
| >= 512 B | 601 | 678 |

**13,408 of the unnamed are under 128 bytes** — accessors, thunks and template
instantiations, which is most of the gap between 21.7% named and 100% and is
largely not game logic.

## What that implies

Further naming has to come from **structure rather than text**: call-graph
position, vtable shape, data-flow into known fields, and the file attribution
built from the client's asserts. The remaining string yield is small and its
best parts are spent.

## The fifth lever, measured 2026-09-16: the logger's *embedded* labels

This file previously noted that "the same logger is a broader source: 452 of its
1,404 call sites carry a literal format string, 260 of them inside still-unnamed
functions", and left it as unexploited. It is now measured, and it splits into
two things with wildly different value.

Re-measured on the current dump: **1,242 logger calls carry a literal, in 893
functions, 311 of them still `FUN_`** — 219 with exactly one literal.

### The one-part label `Name::` or `Name : ` — DO NOT USE

219 unnamed functions begin their message with something that looks like a name.
Controlled against **already-named** functions with the same shape:

	label matches the function's own name:    0
	label does not match:                   131        agreement 0.0%

Zero. The mismatches say what the label really is: `CAgentMsg`, `AQ_OpenMarket`,
`CLobby` — the **class or subsystem**, not the method. And it is not reliably
even that: tested against the function's namespace it reaches only **76.1%**,
with the misses being inherited methods logging their base class
(`CGCOSInventoryOP` functions logging `CGStorageOP`) and the odd method name
appearing where a class should be.

76% is a coin weighted 3:1, not a lever. Applying these would have invented 219
names, which is the largest single fabrication this project has come close to.

### The two-part label `Class::Method ` — 100%, and nearly spent

The same messages sometimes carry BOTH parts. That form is a different animal:

	control over already-named functions:  35 match, 0 miss   (100.0%)

Perfect, and cleanly separable from the one-part form by regex. Its yield is
**two** still-unnamed functions, both applied:

	0046dde0  trs_sm_trainingcampjob::vslot_007 -> Unlock
	00621fd0  GObjPC::FUN_00621fd0             -> RemoveSiegeObject
	                                              (label says class CSiegeFortress;
	                                               the GObjPC namespace is call-graph
	                                               inference and the label outranks it)

**The lesson is the split, not the two names.** One regex over the same corpus
gives 0% and another gives 100%, and telling them apart cost one control run.
A lever is not "text that looks like a name" — it is a pattern whose agreement
with known answers has been measured.

## Two more levers, measured and closed (2026-09-20, round 284)

Both were proposed as "structure rather than text" candidates and both were
controlled before use, per the rule this page ends on.

**Class attribution vs. assert file — 95.4 %, and not a lever.** For the 348
functions in `client_translation_units.tsv` that already carry a class-qualified
name, does the class agree with the `.cpp` the assert names? 332 yes, 16 no. The
misses are legitimate rather than errors: a class may live in a file named for
something else (`CVBDynamic` in `VertexBuffer.cpp`, `CPrimBranch` in
`PrimSkeleton.cpp`, `SWorld` methods in `Map.cpp`). So this is a **cross-check
that validates both attributions**, not a source of new names.

**SQL procedure literals — already spent.** 31 server functions issue a
`{?=CALL _PROC}` literal, 20 of them still `FUN_`. Controlled against the 11
already named: the agreement is *semantic*, not lexical
(`AQ_StorageUpdater::DeleteItem` for `_STRG_DEL_ITEM`,
`CTimedJob::PersistToDBForPet` for `_ADDTIMEDJOBFORPET`), so the literal
describes the function but does not spell its name. And
`docs/protocol/persistence.md` had already harvested all three call forms --
39 `{?=CALL}`, 26 `{CALL}`, 7 `EXEC` -- which is more than this pass's grep
found.

**What was open there, and moved instead:** that page's "the parameters of any
procedure are not recovered". Two are now partly traced, by a rule worth
keeping: **an argument that is also passed to a known accessor names itself**
(a `%d` handed to `CGStorage::GetItem` is a storage slot). See
`persistence.md`.

## A sixth source: names this project already recovered and never filed (round 302)

`recovered_names.tsv` is what the Ghidra applier consumes, so a name that exists
only in a page's prose never reaches the dump -- and every sweep since counts
that function as unnamed. Round 301's emitter sweep listed
`GObjPC::FUN_004a9050` among its unnamed yield while `ground_items.md` had
**read the function in full** and called it `GObjPC::CheckCanPickUp`.

**The sweep.** Mining `` `Class::Method` `` beside `` `0x…` `` across `docs/` found
**160 addresses named in prose**, of which **39 were not in the TSV**. Verified
against the dump, they split:

| | |
|---|---:|
| already named in the dump (so correctly absent -- this file is for names the dump lacks) | 9 |
| **not a function start at all** -- the regex paired a name with a nearby constant | 4 |
| **false pairing** -- the address belongs to a *different* function in the same sentence | 1 |
| named in prose, `FUN_` in the dump: **filed** | **4** |
| contradictions, left for a reading pass | 5 |

**Every row had to be verified, and a third of the plausible ones were wrong.**
`0xb45b44` "named" `CGStorage::CheckRentalItemValidity` is a float constant
(10.0). `party.md`'s sentence reads "…`CParty::CheckCanCreate`, and hands the
byte to `0x5be280`" -- the address is the *callee*. `0x410110` picked up
`Formula_SkillPhysDamage` from a neighbouring line when it is
`Formula_ExpRewardForContributor`. A regex over prose proposes; the dump
disposes.

### The contradictions, recorded rather than resolved

| address | prose says | the dump's RTTI says |
|---|---|---|
| `0x45e620` | `AQ_StorageUpdater::DoWork` | `AQ_StorageUpdaterForPacakageItem::DoWork` |
| `0x483e80` / `0x483eb0` | `CGObjSiegeStruct::CanRepair` / `CanRevive` | `CGObjCOS_Summoned::CanRepair` / `CanRevive` -- and a **separate** `CGObjSiegeStruct::CanRepair` exists at `0x4cecd0` |
| `0x4a9fc0` / `0x4aa5b0` | `CGObjChar::SetBerserk` / `IsBerserk` | `CGObjCOS_Summoned::SetBodyMode` / `GetBodyMode` |

The last pair is not a disagreement about the code -- berserk *is* body mode
(`GetBodyMode() == 1`) -- it is the shared-implementation hazard
`persistence.md` documents, where the class prefix names an arbitrary member of
the sharing set. The first two are worth a reading pass before either name is
trusted.


## The denominator had two files in it, and the dump had neither (round 305)

Two corrections to how naming coverage is counted here.

**1. There are two name sources.** Besides `docs/protocol/recovered_names.tsv`
(2,421 rows), `client/tools/ghidra/ApplyKnownNames.java` carries a hardcoded
table of **191 names, 152 of which appear nowhere else**. Any census that reads
only the TSV understates what the project has named -- round 302's prose sweep
and round 303's tracker test both did. `internal/systems.AllRecoveredNames`
merges them, and `TestTheTwoNameSourcesDoNotContradict` keeps them from making
different claims about one function.

**2. A filed name is not an applied name.** On 2026-09-20, **250 of the 2,079
server rows** in the TSV were still `FUN_` in the dump -- 12 %. Filing a row
touches nothing: `ApplyRecoveredNames.java` must be run, and `PROJSTAMP`
cleared so `re_tick.sh` rebuilds. See the recipe in `docs/RE_LOOP.md`.

**Coverage, re-measured after the apply and the rebuild** (`SymbolReport.java`):
server NAMED **5,355 (15.7 %)**, client **2,219 (5.1 %)**, against 5.3 % / 3.0 %
on 2026-09-17. Most of the server's rise is SLOTTED falling 5,617 -> 2,579, not
the apply. Full tiers in `absence_audit.md`.

**The consequence for every sweep on this page**: a census of `FUN_` functions
in the dump measures *applied* names, not *recovered* ones, and the two drift
apart by however many rounds have passed since the last apply. Run the apply
before quoting a coverage number, or the number counts work already done as
work outstanding -- which is precisely what sent round 301 to re-derive
`GObjPC::CheckCanPickUp` and cost round 302 its tick.


## A lever that looked obvious and scored 18 % (round 313)

Rounds 307-308 recovered 409 runtime-table columns with their struct offsets.
The obvious next move is to name unnamed functions by the offsets they touch: a
function reading several `_CHAR` offsets ought to be character code.

**Measured against known answers, the way this page requires, it fails.**
Control: the 5,621 already-named server functions, of which 425 name themselves
character code (`CInstancePC`, `GObjPC`, `CharData`, `CGObjChar`, `Char_`).
Scoring every function by how many of `_CHAR`'s 43 offsets it touches:

| threshold | selected | actually character code | precision | recall |
|---:|---:|---:|---:|---:|
| >= 4 | 117 | 21 | **18 %** | 5 % |
| >= 6 | 43 | 6 | 14 % | 1 % |
| >= 8 | 26 | 3 | 12 % | 1 % |
| >= 10 | 17 | 3 | 18 % | 1 % |
| >= 12 | 6 | 1 | 17 % | 0 % |

**Precision does not rise with the threshold**, which is the signature of noise:
a real signal concentrates at the top. Against this page's own bar -- the
two-part `Class::Method` form scored 35/35, the one-part `Name::` scored 0/131
and was rejected -- 18 % is not close.

Weighting by rarity does not save it. 38 of the 43 offsets are used by under 1 %
of functions individually, so the filter removes almost nothing, and the
counterexample is decisive: **`__get_lc_time`, a CRT locale routine, touches 17
of them.**

**Why it cannot work.** Struct offsets are not a vocabulary. Any sizeable
function touches dozens of small offsets incidentally, so the overlap measures a
function's SIZE far more than its subject. The offsets remain valuable for the
reverse lookup they were built for -- given `charData+0x86`, name the column --
and that is a different question from naming the function that touches it.


## The client assert lever, closed for NAMING (round 319)

`client_asserts.md` harvested every `Assert_FileLineExpression` call. This page
has listed that as done without saying what it is worth as a *naming* lever.
Measured now:

| | |
|---|---:|
| client functions containing an assert | **458** |
| of those, still `FUN_` or `vslot_` | **437** |
| whose expression contains a `Class::Member` or a call | 88 |
| whose expression quotes **its own** class or name | **0** |

**The control, on the 21 assert-carrying functions that ARE named**, shows what
the working form looks like -- the expression quotes the function itself:

	GScript::SaveGameData                     <- "SaveGameData(), dwID == SCR_INVALID_VALUE"
	GlobalDataManager::...GetTIDFromObjectID  <- "CGlobalDataManager::GetTIDFromObjectID ( 0x%X )"
	Game::CObjChild__m_pGfxEttManager         <- "CObjChild::m_pGfxEttManager->GetUsedIDNum() == 0"

and what the non-working form looks like -- the expression names a variable or
a *different* function:

	CObjCharacter::SetDefaultWear             <- "(nEquipSlot >=0 ) && ( nEquipSlot < EQUIP_VISUAL_COUNT)"
	IFSkillMastery::...SetMasteryData         <- "m_pMasteryData"

**Those three are the only instances in the binary.** Of the 88 unnamed
candidates, **none** quotes its own class -- they assert container sizes
(`m_sRegionList.size()==0`), handles (`ar.IsOpen()`) or calls to other
functions (`FindHeight(vPos)`). An assert expression describes *the state being
checked*, and only rarely the function checking it.

**So the lever is spent for naming and remains valuable for attribution.** The
file and line still place a function in its source file and order it against its
neighbours, which is the SLOTTED/ATTRIBUTED tier this page distinguishes from
NAMED -- knowing *where* a function lives, not what it does.
