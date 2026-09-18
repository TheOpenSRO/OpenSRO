# The stat tag vocabulary

**Recovered 2026-09-18.** `Stat_ApplyTaggedModifier` (`0x00498690`) dispatches on a
three-character tag and writes the corresponding ParamKeeper param. The tags are the
**binary's own labels** for its stat parameters, so they name params that were previously
known only by number.

## Reading the tags

The tags arrive as MSVC multi-char literals, which are stored **big-endian**:

	4988e4  cmp eax,0x637269    ; 0x63 0x72 0x69 -> 'cri'
	4988eb  cmp eax,0x657261    ; 0x65 0x72 0x61 -> 'era'

Decoding them little-endian spells every tag backwards (`irc`, `are`), which is the error
that once agreed with **zero** of fourteen recorded pairs.

## The map

Each row is one `cmp eax,<tag>` site, the param id the branch loads into EDI, and the slot
it pushes. A branch that leaves the column blank **jumps into a shared tail** and does not
set the value within its own block — those are listed, not guessed.

  tag    at        field        param  slot
  'vbl'  004986c7  -            56     0
  'hpa'  004986d8  -            3      -
  'bri'  004987c4  +0x1a4       10     -
  'ape'  004987eb  -            27     -
  'cri'  004988e4  +0x1dc       12     -
  'era'  004988eb  -            9      1
  'tha'  004989bc  -            -      -
  'rep'  004989cd  -            -      -
  'hra'  004989de  -            11     1
  'int'  004989e9  -            -      -
  'mpa'  004989f0  -            4      -
  'str'  00498aa2  -            1      -
  'str'  00498aa9  -            -      -
  'rua'  00498af5  -            128    -
  'rna'  00498b06  +0x1a4       128    -
  'ara'  00498b11  -            174    -
  'als'  00498c83  -            27     0
  'ntv'  00498c94  -            -      -
  'prg'  00498ca5  -            25     1
  'vcr'  00498cb6  -            57     0
  'pmp'  00498cc1  -            25     -
  'pna'  00498cc8  -            52     1
  'pna'  00498e15  -            53     1
  'prg'  00498f08  -            26     1
  'rep'  00498f0f  -            26     1
  'sti'  00499027  -            -      -
  'eis'  00499038  -            -      -
  'csi'  00499041  -            -      -
  'dii'  00499048  -            -      -
  'ein'  0049904f  -            -      -
  'fei'  004990aa  -            -      -
  'sli'  004990b1  -            -      -
  'trj'  00499104  -            -      -
  'oli'  0049910d  -            -      -
  'tra'  00499118  -            -      -
  'trv'  0049916e  -            -      -
  'mdu'  00499175  -            259    -

## Why this map is trusted

Three tags land exactly where a separately recovered document already put those params:

	'str' -> param 1      stat_graph.md has param 1 as Strength
	'hpa' -> param 3      param 3 heads the MaxHP chain (3 <- 54 <- 52 <- 1)
	'mpa' -> param 4      param 4 heads the MaxMP chain (4 <- 55 <- 53 <- 2)

and a fourth check is stronger still. The characterdata work recorded
**col 75 = 'era', col 76 = 'bri', col 77 = 'hra', col 78 = 'cri'** — four consecutive
columns. This dispatcher, read independently and from the other end, gives

	'era' -> 9    'bri' -> 10    'hra' -> 11    'cri' -> 12

four consecutive params **in the same order**. Two derivations that share no evidence agree
on the ordering.

`'era'` was additionally read instruction by instruction rather than by script:

	4988f6  test ebx,ebx / fild [esp+0x20]   ; the integer argument
	49890d  push 0x1                         ; slot 1
	49890f  mov edi,0x9                      ; param 9
	498914  call ParamKeeper_SetParam

## What a tag reads

`'cri'` is the one tag whose source field is confirmed by reading rather than by the
script's first-`fld` heuristic:

	498923  cmp DWORD PTR [ebp+0x190],0x1
	49892a  jne 0x498930
	49892c  fldz                     ; gate fails -> 0.0
	498930  fld DWORD PTR [ebp+0x1dc]

so `'cri'` reads character block field `+0x1dc` behind the same `+0x190` gate that
`Char_PublishCombatStats` uses for params 6 and 7. The `field` column for every other tag
comes from a first-match heuristic and is **not** to be relied on; `'bri'` and `'rna'` both
report `+0x1a4`, which is the heuristic showing its limits rather than two tags sharing a
field.

## What is NOT claimed

The obvious expansion of `era`/`bri`/`hra`/`cri` into evasion, block, hit and critical is a
**reading, not a recovery**, and the characterdata notes already flag it as such. Nothing
here promotes it: what is established is the tag text, the param id and, for `'cri'`, the
field. Several tags appear at two sites with different params (`'pna'` -> 52 and 53,
`'prg'` -> 25 and 26, `'str'` twice), which is what a physical/magical or add/subtract pair
looks like, but which pair is which is not read.
