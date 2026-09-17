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

## What this settles: armour does reach the flat absorb

`Formula_MitigatePhysicalDamage` subtracts **param 5** as flat absorption. Four ticks of
enumerating param-5 writers found publishers, skill effects and timed debuffs but no
equipment — because **equipment never writes param 5 directly**:

	item entry -> param 59 -> param 50 -> param 21 -> param 5

`param 59` has exactly two writers: `Char_PublishCombatStats` and
**`RemoveParamKeeperItemEntry`**, the per-item entry function. So an equipped item's
contribution arrives at the flat absorb through the graph.

`param 21` also takes `param 1`, Strength. So the flat absorb has **two upstream
sources, equipment and Strength**, and the magical twin (`6 <- 22 <- 2/51`) mirrors it
with Intellect.

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

**So equipment does not add to the flat absorb; it scales it.** The absorb is a
Strength-derived base multiplied by a percentage that `param 50` carries, and `param 50`
is where the per-item entries land (via `param 59`). The magical twin is identical with
Intellect and `param 51`.

## What is NOT read

- **How a base slot combines several contributors.** `58 -> 50` and `59 -> 50` both
  land in slot 0, and the branch of `FUN_004b2e60` that handles slot type 0 was not
  read, so whether they sum or replace is unknown.
- **Which aggregate fields 58 and 59 are.** `Char_PublishCombatStats` writes both out of
  the block `Char_BuildAggregateStats` fills, and which characterdata columns those are
  has not been traced.

**What this means for srrevamp, and why nothing was changed yet.** `defenderArmor` adds
armour into the flat term. The engine multiplies: a Strength base scaled by an
equipment-fed percentage. That is a different model, not a different constant, so
changing it is a real behaviour change and it needs the two unread pieces above first --
otherwise a character with armour and no Strength would come out with an absorb of zero
on a reading that is only three quarters done.
