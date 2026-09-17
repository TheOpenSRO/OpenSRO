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

## What is NOT read

**The arithmetic at each node.** `BindDerived` records that 5 depends on 21; the
coefficient lives in `GParamKeeper::ParamKeeper_EvaluateParam` (`0x004b3210`), which is
unread. So the *shape* is grounded and the *weights* are not: nothing here says how much
armour or how much Strength.

srrevamp's `defenderArmor` sums armour into the flat term, which matches the equipment
half of this shape. The Strength half is absent from srrevamp and should not be added
until `ParamKeeper_EvaluateParam` gives the arithmetic.
