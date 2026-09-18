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

Tag, the site that tests it, the param it writes, the slot, and the developers' description
where the dump function supplies one.

	'evbl' 004986c7  param 56    slot 0    evbl +%d%%
	'hpa'  004986d8  param 3     slot -    Ava hp +%d
	'mp'   004986e9  param 4     slot 0    mp +%d
	'fz'   004986fa  param -     slot -    anti-frostbite +%d%%
	'fz'   0049871a  param -     slot -    anti-frostbite +%d%%
	'bu'   00498733  param 27    slot -    anti-burn +%d%%
	'es'   0049873e  param 29    slot -    anti-eshock +%d%%
	'bri'  004987c4  param 10    slot -    block rate +%d
	'ps'   004987d5  param -     slot -    
	'zb'   004987e0  param -     slot -    anti-zombie +%d%%
	'ape'  004987eb  param 27    slot -    ape(%d%%): %d,
	'ps'   0049880b  param 31    slot -    
	'zb'   00498812  param 31    slot -    anti-zombie +%d%%
	'cri'  004988e4  param 12    slot -    critical +%d
	'era'  004988eb  param 9     slot 1    
	'atha' 004989bc  param -     slot -    atha(%d%%): %d
	'rep'  004989cd  param -     slot -    
	'hra'  004989de  param 11    slot 1    
	'int'  004989e9  param -     slot -    Ava hr +%d%%
	'mpa'  004989f0  param 4     slot -    Ava mp +%d
	'str'  00498aa2  param 1     slot -    
	'astr' 00498aa9  param -     slot -    astr +%d
	'drua' 00498af5  param 128   slot -    Ava daru +%d%%
	'brna' 00498b06  param 128   slot -    
	'dara' 00498b11  param 174   slot -    Ava dara +%d%%
	'rals' 00498c83  param 27    slot 0    
	'intv' 00498c94  param -     slot -    
	'hprg' 00498ca5  param 25    slot 1    Ava hprg +%d%%
	'evcr' 00498cb6  param 57    slot 0    
	'hpmp' 00498cc1  param 25    slot -    regen hpmp +%d%%
	'hpna' 00498cc8  param 52    slot 1    
	'mpna' 00498e15  param 53    slot 1    
	'mprg' 00498f08  param 26    slot 1    Ava mprg +%d%%
	'nrep' 00498f0f  param 26    slot 1    
	'rsti' 00499027  param -     slot -    
	'reis' 00499038  param -     slot -    
	'rcsi' 00499041  param -     slot -    
	'rdii' 00499048  param -     slot -    resist disease +%d%%
	'rein' 0049904f  param -     slot -    reinforce +%d%%
	'rfei' 004990aa  param -     slot -    
	'rsli' 004990b1  param -     slot -    resist sleep +%d%%
	'strj' 00499104  param -     slot -    
	'soli' 0049910d  param -     slot -    resist stun +%d%%
	'stra' 00499118  param -     slot -    Ava str +%d
	'strv' 0049916e  param -     slot -    
	'umdu' 00499175  param 259   slot -    
## What the descriptions settle

The description column is the game's own text, so it grounds readings this page previously
refused to promote:

	'bri'  ->  "block rate +%d"     param 10
	'cri'  ->  "critical +%d"       param 12
	'hpa'  ->  "Ava hp +%d"         param 3   (the MaxHP chain head)
	'mp'   ->  "mp +%d"             param 4   (the MaxMP chain head)

The evasion/block/hit/critical reading of `era`/`bri`/`hra`/`cri` was carried for two ticks as
"the obvious READING, not a recovery". For `'bri'` and `'cri'` it is now a recovery.

**It also identifies part of the 25-32 block**, which had been listed as unidentified:
`'bu'` -> param 27 is "anti-burn" and `'es'` -> param 29 is "anti-eshock", so that run is the
**resist family**. The other resists the dump names — frostbite, toxin, zombie, disease,
sleep, stun, fear, csmp — belong to the same run, but only the two with a resolved param are
claimed here.

## What is still NOT claimed

- Twenty tags have no description in the dump function, and several have no resolved param
  because their branch jumps into a shared tail. Both are left blank rather than filled in.
- `'int'` prints `"Ava hr +%d%%"` in the dump, which is almost certainly a copy-paste slip in
  the game's own code — `'hr'` prints the same string. It is recorded as what the binary says,
  not repaired.
- Tags appearing at two sites with different params (`'pna'` -> 52 and 53, `'prg'` -> 25 and
  26) are a physical/magical or add/remove pair; which is which is not read.
