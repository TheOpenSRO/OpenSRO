# The character lock, `chardata + 4`

A one-byte flag on the character record that, while set to 1, makes the server
refuse a specific list of player actions. It is not a game rule the player can
see — it is a **concurrency guard** held while an asynchronous database query or
a multi-step transaction is in flight against that character.

Recovered 2026-09-21 (round 360). Every claim below is from the server dump.

## The byte

`GObjPC + 0x30` is the character record (`chardata`); the dump writes it as
`pc[0xc]` when the object is typed `int *`. Byte `+4` of that record is the lock.
Byte `+6` sits beside it and is tested in the same breath by several gates; `+7`
is the pending-invitation state byte recovered in rounds 356–359
(`docs/protocol/party.md`).

## It has exactly one writer

	void __thiscall GObjPC::SetLocked(int pc, char locked)
	{
	  if (locked != *(char *)(*(int *)(pc + 0x30) + 4))
	    *(char *)(*(int *)(pc + 0x30) + 4) = locked;
	  if ((locked == '\x01') && (*(int *)(pc + 0x188) != 0))
	    (**(code **)(**(int **)(pc + 0x188) + 0x10))();
	  return;
	}

`0x004a9df0`, reached as **vtable slot 342 (offset 0x558)** on every mobile
class the RTTI names — `CGObjChar`, `CGObjMob`, `CGObjNPC`, `CGObjNPCNPC`,
`CGObjSiegeObject`, `CGObjSiegeStruct`, `CGObjCOS`, `CGObjCOS_Cart` and 8 more.

**`pc + 0x188` is not claimed.** The lock setter is its only reader in the whole
dump, so what gets poked on the 0→1 edge cannot be identified from use. It is
written `0` in three constructors/resets and non-zero in `FUN_004595d0`.

## What settles the name

Not inference from the call sites — **the engine names it itself**. Of the 50
call sites, two of the functions that call `SetLocked(0)` already carried names
recovered from the binary's own log strings (`origin=engine`, the two-part
`Class::Method` log label that controls 35/35 on already-named functions):

	0046dde0  trs_sm_trainingcampjob::Unlock   logs "trs_sm_trainingcampjob::Unlock ..."
	0046e160  trs_sm_guildjob::Unlock

Both pass **0**. So 0 is Unlock, and 1 is Lock. Only the Unlock side logs; there
is no `::Lock` string in the binary.

## The 50 call sites are one family

Every caller is a job class, and each flips the flag on at entry and off at exit.
Two vtable layouts, with the same pairing:

| Family | Lock | Unlock |
|---|---|---|
| `AQ_*` — asynchronous DB query | slot 9 | slot 10 |
| `trs_sm_*job` — transaction state machine | slot 6 | slot 7 |

The AQ pairing is fixed by the two thinnest instances in the dump, 31 bytes each,
whose entire bodies are the lock call and nothing else:

	AQ_ItemQuotation::Lock   00451180  slot 9   -> SetLocked(1)
	AQ_Trijob::Unlock        00465670  slot 10  -> SetLocked(0)

Both are COMDAT-shared across several AQ vtables (`0x00ae3a68`, `0x00ae3b4c`,
`0x00ae59f0`), so their class prefixes are the dump's attribution of a body
several AQ classes share, not a claim that the body belongs to that one class.

A typical member resolves the character by the id the job stored at `+0x2c`:

	piVar1 = FUN_00485dc0(*(undefined4 *)(job + 0x2c));   // world lookup by id
	if (piVar1 != NULL) (**(code **)(*piVar1 + 0x558))(1);

**The Unlock side is guarded and the Lock side is not**, which is the tell that
this is a lock rather than a mode flag: before clearing, it re-reads the object's
own id through vtable slot 8 and compares it with the id the job stored, so a job
finishing after its character has been recycled cannot unlock a different one.

	iVar2 = (**(code **)(*piVar1 + 0x1c))();
	if ((iVar2 != 1) || (iVar2 = (**(code **)(*piVar1 + 8))(), iVar2 == *(int *)(job + 0x2c)))
	  (**(code **)(*piVar1 + 0x558))(0);

The classes: `AQ_AvatarSpecial`, `AQ_COSManipulator`, `AQ_CharDataLoader`,
`AQ_ItemQuotation`, `AQ_ItemXChanger`, `AQ_OpenMarket`, `AQ_Siege`,
`AQ_StorageExpander`, `AQ_StorageUpdater`, `AQ_StorageUpdaterForPacakageItem`
(the misspelling is the binary's own), `AQ_Trijob`; `trs_sm_gameworldjob`,
`trs_sm_guildjob`, `trs_sm_partyjob`, `trs_sm_trainingcampjob`.

## What a held lock refuses

Read from the bodies, not from the conditions — **the polarity looks split and
is not**. `CParty::CheckCanCreate` tests `!= 1`, but that branch is the *success*
path and the function falls through to `return 0x2c09`; `FUN_00514010` tests
`== 1` and returns immediately. Both refuse when the byte is 1.

| Gate | Refusal |
|---|---|
| `Item_HandleUseItem` `00510980` | using an item |
| `FleaMarket::CFleaMarket__SellFMarketItem` `00472700` | selling on the flea market |
| `CParty::CheckCanCreate` `00513f90` | `0x2c09` |
| `CParty::CheckCanCreateForMatch` `00514170` | party create for match |
| `FUN_00514010` (invite, step 7 of the ladder) | `0x2c06` |
| `CInstanceTrainingCamp::CheckCanCreate` `004e4680` | academy create |
| `TrainingCamp_CheckCanDisband` `004e4780` | academy disband |
| `TrainingCamp_CheckCanInvite` `004e4800` | academy invite |
| `TrainingCamp_CheckCanEnter` `004e4890` | `0x6806` |
| `FUN_00514b20` | `0x4c09` |
| `CGObjChar::Update` `004a88f0` | skips per-tick work while locked |

**It is not death.** `TrainingCamp_CheckCanEnter` checks the lock and the life
state separately, in that order: the lock pair yields `0x6806`, and only then
does the vtable-`0xf8` state getter yield `3` when it is not 1.

## The refusals have no client message, and that is consistent

`0x2c06`, `0x2c09` and `0x6806` are **all absent** from the client's 643-case
message switch (`docs/protocol/error_codes.md`), while their immediate
neighbours are named — `0x2c0a` is `PARTYERR_TOO_LOW_CREATOR_LEVEL`, `0x680f` is
`TC_ERROR_TRAININGCAMP_ALREADY_ENTRY`. A player-facing rule gets a localized
string; a transient race guard the client should never provoke does not. This is
corroboration, not proof: an unnamed code is also just an unnamed code.

## For srrevamp

**Nothing to wire.** srrevamp's Go server does not have this shape — its
character mutations are synchronous inside a request, so there is no window for
a second request to race a database round trip. The value of this round is that
eleven gates that read an unexplained byte now read a named one, and that the
`0x2c06` open item from round 359 is closed.

If the Go server ever grows an async path (a queued trade, a cross-shard
transfer), this is the list of actions the retail server considered unsafe to
allow during one.
