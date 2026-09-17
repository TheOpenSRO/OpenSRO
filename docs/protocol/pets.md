# Pets, carts and the rest of the COS family

**COS is the engine's own abbreviation**, and it covers more than pets — six
classes carry it. "Pet" names only two of the six, which is why
`server/internal/cos` is called what it is.

| class | vtable | slots |
|---|---|---|
| `CGObjCOS` | `0x00af0c1c` | 403 |
| `CGObjCOS_Cart` | `0x00af127c` | 403 |
| `CGObjCOS_Pet` | `0x00af1a4c` | 403 |
| `CGObjCOS_GoldPet` | `0x00af20ac` | 403 |
| `CGObjCOS_SilkPet` | `0x00af270c` | 403 |
| `CGObjCOS_Mercenary` | `0x00af343c` | 404 |

Those 400-slot vtables are the `IGObj` interface every world entity has, which
is why a summoned COS can be attacked, damaged and killed through the same paths
a monster is — and why a pet appears in the object index at all.

## Summoning — `GObjPC::FUN_004fcef0`

One function dispatches every kind, on a switch with cases 1 through 5. Each
case has its own rules, and the pet cases are 3 and 4.

### The level gate, for pets

	bVar3 = GetLevel();                                       // vtable slot 73
	if ((hasOwner && bVar3 < 5) || bVar3 < *(byte *)(item + 0x198))
	    return 0x186c;    // STRGERR_HIGHER_LEVEL_REQUIRED_TO_USE_THISITEM

Two things, in one condition:

- **An absolute floor of level 5**, the same number `party.MinCreatorLevel`
  uses. `CGItemCOSSummoner::vslot_307` (`0x00493100`) enforces it independently,
  so it is read twice from different functions.
- **The item's own requirement, at byte `+0x198` of its reference record.** That
  is per-item data, not a constant, so `server/internal/cos` records the
  **offset** and deliberately no value.

The floor sits behind a `hasOwner` guard; with no owner object only the item's
own requirement applies.

### One pet per type

After the level tests, the function walks the character's active COS objects and
compares type ids:

	if (typeID == requestedTypeID) return 0x18a9;  // COS_CANT_SUMMON_DUPLICATE_PETTYPE

So a character may have several COS out at once, but **not two of the same
type**. A separate refusal, `0x185c` `STRGERR_CANT_SUMMON_MULTIPLE_COSOBJ`,
applies to the kinds that permit only one at all.

### Case 5 wants a guild

	bVar3 = CGuild::GetLevel();
	if (bVar3 < 3) return 5;

**Guild level 3** — the same threshold the fortress war requires to register
(`siege.MinGuildLevel`). Worth noting, but two checks reading one number are two
checks, not one rule; nothing here ties them together.

### `CANT_PETSUM_HIGHLEVEL` reads backwards

`0x18a5` `COSPETERR_CANT_PETSUM_HIGHLEVEL` fires when the **owner's** level is
**below** the pet's requirement — the "HIGHLEVEL" is the pet's, not the
player's. The name is easy to read the wrong way round, so it is written down
here.

## Naming — `FUN_00511bb0`

	if (len == 0 || 0xc < len) { refuse }

so a pet name is **1 to 12 characters**, validated against the `std::string`
size field. Note this is *not* the guild-name rule (`2` to `12`,
`docs/protocol/guild.md`): the maximum matches and the minimum does not, so the
two cannot share a helper.

The naming procedure is `_COS_Naming`, 2 arguments.

## The rest of the vocabulary, enumerated

Twenty-five COS codes exist and seventeen server functions return one. Beyond
those above:

| area | function | codes |
|---|---|---|
| dismissal | `FUN_00511a60` | `CANT_DEACTIVATE_IN_DEADSTATE`, `CANT_PETRE_BATTLE` |
| selling | `FUN_00511f40` | `CANT_SELL_COS_HAVE_ITEMS`, `CANT_SELL_REQUESTED_COS` |
| feeding | `CGItemExpendable::vslot_327` | `HGPFULL_NODRINK` — the pet's hunger gauge is full |
| control | `GObjPC::FUN_004d2200` | `YOU_CANT_CONTROL_THIS_OBJ` |
| moving items | `FUN_00523960`, `FUN_00523f70` | `CANT_MOVETO_SUMITEM`, `CANT_MOVETO_CHEST2` |

## The database surface

	_AddNewCOS       12 args        _ChangeCOSState   2 args
	_DeleteCharCOS    3 args        _COS_Naming       2 args

plus the `_CHARCOS` and `_INVCOS` runtime tables. **No column layout is
recovered** for either.

## Not recovered

- **What the five switch cases are.** Cases 3 and 4 are pets, case 5 needs a
  guild, one case is the cart; the mapping from case number to COS kind is not
  established.
- **The hunger gauge** — `HGPFULL_NODRINK` names it and nothing reads its rate,
  capacity or what happens at zero.
- **Pet growth.** `CGObjCOS_GoldPet` and `_SilkPet` are distinct classes and
  nothing here says what distinguishes them beyond their names.
- **The mercenary**, which is the only class of the six with a different vtable
  length and has not been looked at.
