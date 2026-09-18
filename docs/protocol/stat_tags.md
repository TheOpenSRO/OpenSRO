# The stat tag vocabulary

**Recovered 2026-09-18, corrected the same day.** `Stat_ApplyTaggedModifier` (`0x00498690`)
dispatches on a multi-character tag and writes the corresponding ParamKeeper param. The tags
are the **binary's own labels**, and for 26 of them the binary also carries the developers'
own English description.

## Reading the tags — and the mistake that cost this page a rewrite

The tags are MSVC multi-char literals, stored **big-endian**:

	4988e4  cmp eax,0x637269      ; 'cri'
	4986c7  cmp eax,0x6576626c    ; 'evbl'
	4986e9  cmp eax,0x6d70        ; 'mp'

They are **variable length — two, three or four characters.** The first version of this page
decoded exactly three bytes, which silently **truncated every four-character tag and dropped
every two-character one**: `'evbl'` was recorded as `'vbl'`, `'soli'` as `'oli'`, `'stra'` as
`'str'`, and `'mp'`, `'fz'`, `'bu'`, `'es'`, `'ps'` did not appear at all. The table had 37
rows; it should have had **46**.

The error surfaced only by cross-checking against a different function —
`DumpItemOptionsVerbose`, which prints an item's options for a human and therefore holds a
**tag -> English description** table the developers wrote. Its four-character codes could not
be reconciled with the three-character ones here, and the dispatcher's own immediate
`0x6576626c` settled it. Decoding little-endian spells the tags backwards, which is the
*other* way this has gone wrong before.

## The table

One row per tag: the site that tests it, the param it writes, a second param where the
branch defers one, and the developers' description where `DumpItemOptionsVerbose` supplies
one.

	'ape'   004987eb  param -             ape(%d%%): %d,
	'astr'  00498aa9  param -             astr +%d
	'atha'  004989bc  param -             atha(%d%%): %d
	'bri'   004987c4  param 10            block rate +%d
	'brna'  00498b06  param 10            
	'bu'    00498733  param 30            anti-burn +%d%%
	'cri'   004988e4  param 12            critical +%d
	'dara'  00498b11  param 174           Ava dara +%d%%
	'drua'  00498af5  param 128           Ava daru +%d%%
	'era'   004988eb  param 9             
	'es'    0049873e  param 29            anti-eshock +%d%%
	'evbl'  004986c7  param 56            evbl +%d%%
	'evcr'  00498cb6  param 57            
	'fz'    0049871a  param 27     +28    anti-frostbite +%d%%
	'hpa'   004986d8  param 3             Ava hp +%d
	'hpmp'  00498cc1  param 25            regen hpmp +%d%%
	'hpna'  00498cc8  param 52            
	'hprg'  00498ca5  param 25            Ava hprg +%d%%
	'hra'   004989de  param 11            
	'int'   004989e9  param -             Ava hr +%d%%
	'intv'  00498c94  param 2             
	'mp'    004986e9  param 4             mp +%d
	'mpa'   004989f0  param 4             Ava mp +%d
	'mpna'  00498e15  param 53            
	'mprg'  00498f08  param 26            Ava mprg +%d%%
	'nrep'  00498f0f  param -             
	'ps'    0049880b  param 31            
	'rals'  00498c83  param 27            
	'rcsi'  00499041  param -             
	'rdii'  00499048  param -             resist disease +%d%%
	'rein'  0049904f  param -             reinforce +%d%%
	'reis'  00499038  param -             
	'rep'   004989cd  param -             
	'rfei'  004990aa  param -             
	'rsli'  004990b1  param -             resist sleep +%d%%
	'rsti'  00499027  param -             
	'soli'  0049910d  param -             resist stun +%d%%
	'str'   00498aa2  param 1             
	'stra'  00499118  param -             Ava str +%d
	'strj'  00499104  param 1             
	'strv'  0049916e  param 1             
	'umdu'  00499175  param 259           
	'zb'    00498812  param 32            anti-zombie +%d%%

## How a branch is resolved

A tag branch does **not** write inline. It sets the param id in EDI, optionally stores a
second id in `[esp+0x24]`, and **jumps into a shared tail** that performs one or two
`ParamKeeper_SetParam` calls:

	4987fc  mov edi,0x1b               ; 'fz' -> param 27
	498801  mov DWORD PTR [esp+0x24],0x1c   ; and a deferred param 28
	498809  jmp 0x498829               ; the shared tail

That shape defeated two earlier passes. A linear scan stopped at the next tag test and saw
nothing; CFG reachability walked past the tail and collected whichever param came next. The
resolver follows unconditional jumps, treats the conditional as the int-to-float sign fixup
it is, and stops at the next `cmp eax,<tag>`.

Its output was checked against a block read by hand -- `'bu'`, `'es'`, `'ps'`, `'zb'` and
`'fz'` -- and agrees on all five, including `'fz'` writing **two** params.

## What the descriptions settle

The description column is the game's own text, so it grounds readings this page previously
refused to promote:

	'bri'  ->  "block rate +%d"     param 10
	'cri'  ->  "critical +%d"       param 12
	'hpa'  ->  "Ava hp +%d"         param 3   (the MaxHP chain head)
	'mp'   ->  "mp +%d"             param 4   (the MaxMP chain head)

The evasion/block/hit/critical reading of `era`/`bri`/`hra`/`cri` was carried for two ticks as
"the obvious READING, not a recovery". For `'bri'` and `'cri'` it is now a recovery.

**It identifies the 27-32 run as the resist family**, which had been on the open list as
unidentified. Reading the branches rather than trusting a scan gives:

	27, 28  'fz'  anti-frostbite   (one tag, two params)
	29      'es'  anti-eshock
	30      'bu'  anti-burn
	31      'ps'  -- not named by the dump function
	32      'zb'  anti-zombie

**CORRECTION.** This page previously said `'bu'` -> param 27 is "anti-burn". That was a
scanner artifact: `'bu'` is `mov edi,0x1e` = **param 30**, and param 27 belongs to `'fz'`,
which writes 27 *and* 28. Only `'es'` -> 29 survived unchanged. The wrong pairing was
published from a script's output without reading the branch, which is the exact failure the
project's own rule warns about.


## The status resists are a second mechanism

The elemental resists write ParamKeeper params. The **status** resists do not. Their branches
call `Char_InsertResistEntry` with a small category index in EAX, which indexes an array of
24-byte associative containers at `object+0x20` and inserts through a red-black tree
(`StdMap_InsertNode`). The index is invisible in the decompilation, because EAX is not mapped
to a parameter.

	'rsli'  index 0    "resist sleep +%d%%"
	'rfei'  index 3    "resist fear +%d%%"
	'rsti'  index 7    -- not named by the dump function
	'rdii'  index 8    "resist disease +%d%%"
	'rcsi'  index 15   "resist csmp +%d%%"

`'rals'` inserts here as well as writing params 27-32, which is consistent with it being
"resist all" — it covers both mechanisms.

`'soli'`, which the dump names **"resist stun"**, is recognised by the dispatcher and then
jumps straight to the plain epilogue: it is **accepted and ignored**. That is worth stating
because a reader seeing the tag in an item's options would reasonably expect it to do
something.

**What these indices are is not claimed.** They are small integers into a per-character array
of containers, and the abnormal-state code space recovered elsewhere is also 0..31 — but that
array is at `object+0xc` with a `0x1c` stride and this one is at `object+0x20` with `0x18`,
so they are **different arrays**. Reading the resist names onto abnormal-state codes would be
exactly the kind of matching-shapes inference this project has been burned by. `'rsti'` in
particular is *not* recorded as stun: the dump gives that name to `'soli'`.

## What is still NOT claimed

- Twenty tags have no description in the dump function, and several have no resolved param
  because their branch jumps into a shared tail. Both are left blank rather than filled in.
- `'int'` prints `"Ava hr +%d%%"` in the dump, which is almost certainly a copy-paste slip in
  the game's own code — `'hr'` prints the same string. It is recorded as what the binary says,
  not repaired.
- Tags appearing at two sites with different params (`'pna'` -> 52 and 53, `'prg'` -> 25 and
  26) are a physical/magical or add/remove pair; which is which is not read.
