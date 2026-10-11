# The derived-stat graph

Recovered 2026-09-17 from `GObjPC::GObjPC_InitStats` (`0x004e3200`), which binds every
edge with `GObjPC::ParamKeeper_BindDerived`. A param is not written directly when it is
derived: a source param changes and the keeper propagates.

## How it was decoded

The two ids reach `ParamKeeper_BindDerived` in `EDI` and `EBX`, and MSVC builds them by
chaining `lea` off the previous pair rather than loading fresh constants:

	004e3296  mov edi,0x3
	004e3298  lea ebx,[edi+0x33]        ; 3, 54
	004e329e  call ParamKeeper_BindDerived
	004e32a1  lea edi,[ebx-0x32]        ; 4
	004e32a4  lea ebx,[edi+0x33]        ; 55
	004e32ab  call ParamKeeper_BindDerived

Matching each call against the nearest literal recovers almost nothing; simulating the
chain recovers **all 30 edges**. The first two reproduce the MaxHP and MaxMP chains this
project recovered separately, which is the check that the decoding is right.

## The edges

	derived <- source        derived <- source        derived <- source
	  3  <- 54                 5  <- 21                17 <- 34
	  4  <- 55                 6  <- 22                18 <- 36
	 54  <- 52                21  <- 1  (Strength)     19 <- 35
	 55  <- 53                22  <- 2  (Intellect)    20 <- 37
	 52  <- 1  (Strength)     21 <- 50                 50 <- 58
	 53  <- 2  (Intellect)    22 <- 51                 51 <- 59
	 13  <- 17                50 <- 59                 51 <- 59
	 14  <- 18                11 <- 0                   9 <- 0
	 15  <- 19                16 <- 20
	 16  <- 20                17 <- 1, 18 <- 1, 19 <- 2, 20 <- 2

## What this settles, and what it does not

`Formula_MitigatePhysicalDamage` subtracts **param 5** as flat absorption, and nothing
writes param 5 for a player except the publisher, skill effects and timed debuffs. The
chain that produces it is:

	characterdata -> block[0x6c], block[0x6d] -> params 58, 59 -> param 50 -> param 21 -> param 5
	                                                                Strength  ->  param 21

`param 59` has exactly two writers: `Char_PublishCombatStats` and
`RemoveParamKeeperItemEntry`. **The second writes 0.0** (see the retraction below), so
this does not show equipment reaching the absorb.

**CORRECTED 2026-09-18: "nothing writes param 5 except the publisher, skill effects and
timed debuffs" was too loose.** Resolving the param id at every `ParamKeeper_SetParam`
call site shows param 5 has **twelve write sites in eight functions** -- see
[param_writers.md](param_writers.md) for the full map, including the callback pair
`FUN_004a4cc0`/`FUN_004a5160` that no call-graph search finds, because they are reached
only through pointers installed into object fields.

`param 21` takes `param 1`, Strength, as its base and `param 50` as its scale, and the
magical twin (`6 <- 22 <- 2/51`) mirrors it with Intellect.

## The slots, which are the arithmetic

`ParamKeeper_BindDerived` takes source in `EBX`, target in `EDI` and **the slot on the
stack** (its own recovered comment states the direction, and Level/Str/Int only ever
appear as `EBX`). The slot decides how the source enters the target, because
`ParamKeeper_EvaluateParam` combines a param's four slots as

	value = base * (1 + pct/100) * mult * (scale/100)

Decoded with the slot, the flat-absorb chain reads:

	Strength -> 21   into slot 0  (base)
	50       -> 21   into slot 3  (SCALE)
	21       -> 5    into slot 0  (base)
	58 -> 50, 59 -> 50   into slot 0 (base)

and `GParamKeeper::FUN_004b2e60` combines a slot's contributors by slot type: a scale
slot starts at **100.0** and each contributor composes as `acc = contrib * acc / 100`.

So the absorb is a Strength-derived base multiplied by a percentage `param 50` carries,
and the magical twin is identical with Intellect and `param 51`.

**Round 769 note:** params 58 and 59 come from the worn ARMOUR's and SHIELD's own PDStr / MDInt
(itemdata columns 82-85, /1000), published with context 0 by Char_PublishCombatStats (READ,
0x497ca9 / 0x497cf4) -- not from characterdata, as the paragraph below supposed for a player. With
context 0 the last piece published wins (INFERRED); OpenSRO still models no flat absorb.

**RETRACTED 2026-09-18: the claim that equipment feeds `param 50`.** It rested on
`RemoveParamKeeperItemEntry` being one of `param 59`'s two writers. Reading the *value*
at that site shows `fldz` — it writes **0.0**, twice, to params 58 and 59. It clears the
contributions before a republish; it is not a contribution.

What actually feeds 58 and 59 is read, and it is not equipment:

	Char_PublishCombatStats  0x00497e6d  fld [ebp+0x1b0] ; *100 -> param 58
	                         0x00497ea7  fld [ebp+0x1b4] ; *100 -> param 59

`+0x1b0` and `+0x1b4` are block fields `[0x6c]` and `[0x6d]`, and the only function
writing those on a character is `Char_BuildAggregateStats`, which interpolates them from
**characterdata columns**. So for a player, whose characterdata row carries zeros, 58 and
59 are zero, the scale is zero, and the flat absorb is zero — with no equipment appearing
anywhere in this chain.

**PARTLY ANSWERED 2026-09-18.** An equipped item reaches the ParamKeeper through its
**magic options**, not through the base defence chain: `IBindingOptionOP` slot 3 decodes up
to 12 packed entries off the item record and applies each one through
`Stat_ApplyTaggedModifier`. See [item_magic_options.md](item_magic_options.md) for the route
and [stat_tags.md](stat_tags.md) for the vocabulary. **Params 5 and 7 are now shown to be unreachable from that path**: the tag dispatcher's
complete set of writable param ids was enumerated, including both computed EDI values, and
neither 5 nor 7 is in it. So the flat absorb and the percentage reduction are character-side
values that equipment does not touch by either route in this build.

## What is NOT read

- **How a base slot combines several contributors.** `58 -> 50` and `59 -> 50` both
  land in slot 0, and the branch of `FUN_004b2e60` that handles slot type 0 was not
  read, so whether they sum or replace is unknown.
- **Which aggregate fields 58 and 59 are.** `Char_PublishCombatStats` writes both out of
  the block `Char_BuildAggregateStats` fills, and which characterdata columns those are
  has not been traced.

**What this means for OpenSRO, and why nothing was changed yet.** `defenderArmor` adds
armour into the flat term. The engine multiplies: a Strength base scaled by an
equipment-fed percentage. That is a different model, not a different constant, so
changing it is a real behaviour change and it needs the two unread pieces above first --
otherwise a character with armour and no Strength would come out with an absorb of zero
on a reading that is only three quarters done.
