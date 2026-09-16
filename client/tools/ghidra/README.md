# Ghidra decompile helpers

Headless GhidraScripts for reading the retail SRO client (`sro_client.exe`) on the
RE box. They exist because, on that box's Ghidra 12.1.3, the GhidraMCP plugin is
broken (incompatible `.jar`, no `:8080` server), so decompilation goes through
`analyzeHeadless` instead of the MCP bridge. **They read a binary you supply; the
repo ships no game data.**

## Running (on the RE box, as the `ghidra` user)

```
scp client/tools/ghidra/DecompDump.java root@<rebox>:/var/tmp/
ssh root@<rebox> "su ghidra -s /bin/bash -c '\
  /opt/ghidra_12.1.3_PUBLIC/support/analyzeHeadless \
    /home/ghidra/re_client sro_client_re \
    -process sro_client.exe -readOnly -noanalysis \
    -scriptPath /var/tmp -postScript DecompDump.java <args> > /var/tmp/hl.log 2>&1'"
```

`println` output is line-prefixed `INFO  <Script>.java> ...` in the log — strip it
with `sed 's/.*<Script>.java> //'` before grepping.

## DecompDump.java `<needle> <max> <mode>`

- `mode=name` — decompile functions whose qualified name contains `<needle>`.
- `mode=addr` — decompile the function(s) containing a comma-separated address list
  (e.g. `0069d380,006a15f0`).
- `mode=list` — just print matching qualified names (fast locate).

The `sro_client_re` project has **no applied symbol names** (every function is
`FUN_00xxxxxx`), so `name`/`list` rarely match. Use `StrXref.java` to find code by
the strings it references, then `DecompDump ... addr` on the addresses it prints.

## StrXref.java `<needle> <maxStrings> [decomp] [maxDecomp]`

Finds defined strings containing `<needle>` and prints the functions referencing
each. The client keeps its source paths and control names as strings
(`"D:\vss-od\Silkroad\Client\client\IFSkillBoard.cpp"`, `"resinfo\ifskillboard.txt"`,
`"CIFSkillBoard"`), so this is the reliable way in. Pass `decomp` to also decompile
the top referencing functions.

## DecompAll.java `<outDir> [timeoutSec] [shardSize]`

**Start here for a binary you are going to ask more than a few questions about.**
Decompiles every function once and writes the C to disk, after which any further
question is a `grep` over local text instead of a ~25-second Ghidra round trip.
That matters because the questions come in chains — a parser leads to a field, a
field leads to its readers, a reader leads to a vtable slot — and it makes the
searches that are otherwise impractical possible at all: *every* call site of a
virtual slot, *every* reader of a struct offset, *every* use of a constant.

Writes `funcs_NNN.c` shards (each function preceded by
`===FUNC=== <entry> <name> size=<bytes>`), an `index.txt` of
`entry / name / size / shard`, and a `DONE` marker written last.

**Poll for `DONE`, not for a process.** `pgrep -f <pattern>` over ssh matches its
own command line, so `until ! pgrep -f "godot4"` never exits — that trap has cost
this project time twice.

### Working the dump: `infn.sh` and `getfn.sh`

A raw `grep` over the shards tells you a pattern matched but not *whose* function
it is, which is almost always the actual question. These two cover it:

```
./infn.sh '\[0x72c\]'      # which functions contain a pattern (file + entry + name)
./getfn.sh 004e3200        # print one function's body, found via index.txt
```

Both default to `/var/tmp/decomp_server` and take the dump directory as a second
argument. Typical loop: `infn.sh` to narrow from 30k functions to a handful, then
`getfn.sh` on each — no Ghidra, sub-second.

**The dump is code only.** Vtables, RTTI and `.rdata` constants are data and do
not appear in it, so grepping a vtable address returns nothing. For those, use
`FindOffsetRefs.java` (`imm` mode for bare constants) or read the PE by RVA.

## FindOffsetRefs.java `<offsets> [max] [mode]`

Finds the code that touches a struct field at a given offset — for when you know
*where* a field lives but not *what it means*. A C++ member access compiles to a
memory operand with a displacement (`MOV EAX, dword ptr [ECX + 0x24c]`), so this
walks the listing and reports operands carrying both a register and that scalar;
requiring the register is what keeps plain immediates out.

- `<offsets>` — one, or a comma-separated list, hex (`0x24c`) or decimal. All of
  them are matched in a **single** pass over the listing, so asking about a whole
  struct at once is cheap; asking one at a time is not.
- `[mode]` — `all` (default) lists every site; `funcs` prints only the
  per-function summary, ordered by hit count, which is usually what you want first;
  `imm` drops the register requirement so a **bare constant** matches
  (`CMP EAX, 0x6d70`). A field lookup and a tag comparison need opposite rules —
  use `imm` to find the code handling an id rather than a struct member. The SRO
  server tags its derived stats with C multi-char literals, so `'mp'` is `0x6d70`
  and `'hp'` is `0x6870`.

Each site is marked `W`/`R` for whether the field was written or read (`CMP`/
`TEST`/`FLD` on the destination operand count as reads, not stores).

**Its best trick is mapping a whole parser.** A `…::ExtractData` deserialises a
row field-by-field, one column per store, so listing its stores *in address order*
gives the column→offset map — anchor it on any field you can identify
independently and the rest fall out. That is how `_RefObjChar` col 59 = MaxHP was
confirmed and an off-by-one in col 79 was caught: `0x19c` was pinned by the
`m_dwMaxHP > 0` assertion, `0x25c` by the code defaulting it to `0xbb8` (3000),
and counting between them fixed every field in the run. Small offsets (`0x4`,
`0x8`) appear in nearly every function and will drown you — this is a tool for
distinctive ones.

## ResolveRegArg.java `<addr[,addr...]> <REG[,REG...]> [maxReport] [annotate] [label]`

**Use this when the decompiled C reads cleanly but tells you nothing.** Ghidra
models one calling convention per function and silently drops any argument that
does not fit it. `ParamKeeper_SetParam` is the case that earned this script: its
297 call sites all decompile to `SetParam(slot, 0, value)` because the
parameter's *identity* travels in `DI`, which never became a parameter. The C is
not wrong, it is incomplete, and nothing in it hints that it is.

It also undoes the constant obfuscation on top. These callers do not load ids
with `MOV` — the optimiser materialises each one from a neighbouring constant as
a ping-pong of `LEA`s (`LEA EDI,[EBX+0x33]` / `LEA EBX,[EDI-0x32]` …), so a grep
for `MOV EDI` finds a few of them and every one it finds is stale. The script
walks each caller forward with a small abstract state over the registers,
models only the forms these chains use (`MOV r,imm` / `MOV r,r` /
`LEA r,[r+imm]` / `XOR r,r`), and marks anything else UNKNOWN rather than
guessing. A branch target clears the state; a `CALL` clears only EAX/ECX/EDX,
since the chains deliberately live in the callee-saved registers.

Several registers at once (`EBX,EDI`) for callees that take more than one —
`ParamKeeper_BindDerived` takes a source *and* a target, and half an edge is
worse than none.

With `annotate`, each resolved value is written back as a pre-comment, which the
decompiler prints into the C. After the next `DecompAll` the dump reads:

```
/* BindDerived source->target: EBX 0x36 (54), EDI 0x3 (3) */
ParamKeeper_BindDerived(0);
```

That is the point: the recovered identity lives in the program, not in a commit
message, and shows up at every call site in every future dump.

## Disasm.java `<entryAddr> [maxInstructions]`

The instructions of one function, with call targets resolved to names. Reach for
it when the C looks complete but a value is missing — the decompiler hides what
does not fit its convention, and only the instruction stream shows a register
being loaded. Reading `PUSH EDI` with no matching `POP` is what settled
`ParamKeeper_SetParam`'s real signature.

## ReadConst.java `<addr[,addr...]>`

Prints an address as int, float and double. Decompiled C shows float constants
as bare `_DAT_00b462ac` symbols, so a formula recovered from the code stops one
step short of being a number without this. All three widths are printed rather
than one guessed; `0x00b45ea0` reads as garbage float and exactly `1.02` double.

## ApplyKnownNames.java `[apply]`

Writes this project's proven findings back into the program as function names,
each with its evidence in a plate comment — so a later reader can audit the name
instead of trusting it. Where behaviour is established but the original
identifier is unknown, the name says what the function *does* rather than
inventing what Joymax might have called it. Separate tables for the server and
the client, chosen by program name. It never overwrites a name that came from
the binary's own assert strings.

## LabelFromUIStrings.java `[apply] [minIdsForModule]`

**The client does not name its UI functions, but it does name its TEXT.** Every
label, message and control caption is fetched by an authored id —
`UIIT_STT_ALCHEMYBOX_TIP_DISMANTLING_BUTTON`, `UIIT_MSG_…`, `UIIT_CTL_…`,
`UIO…` — and those ids sit in the binary as wide string literals. A function
that asks for one is, with certainty, the code behind that piece of interface.
597 functions cite at least one.

Same move as `NamespaceFromSourceFile.java`, on a different fact the binary
states about itself. It produces two things and deliberately keeps them apart,
because they are not equally certain:

- **A plate comment** on all 597, listing the ids verbatim. Pure fact, no
  interpretation — and the reason to run it: a reader of the dump lands in an
  unnamed function and immediately knows which window they are in.
- **A `UI_<module>` namespace**, but only where the evidence is a pattern rather
  than a coincidence: at least two *distinct* ids agreeing on a first segment,
  with none disagreeing. One `UIIT_STT_ACCEPT` earns nothing, because "ACCEPT"
  is a word, not a window; three `UIIT_STT_ALCHEMYBOX_*` earn `UI_ALCHEMYBOX`,
  because that is a place. 140 functions across 48 modules qualify — SILKMALL,
  ALCHEMYBOX, FORT, PARTYMATCH, GUILD, LETTER, SOCKET, ARENA, WORLDMAP.

**Deliberately not done: naming a function after its label.** "the function that
mentions `UIIT_STT_ACCEPT`" is not the same claim as "the accept handler", and
this project does not ship the second when it has only measured the first.

## VtableAttribute.java `[apply] [minSlots] [minAgree]`

**The only lever that reaches virtual functions.** `CodeCensus.java` found
18,522 game-logic functions with no direct caller across the two binaries. They
are not dead — a virtual is reached only through a vtable slot, and Ghidra does
not resolve those, so every call-graph-based lever (`PropagateModules.java` most
of all) steps straight past them. They are also disproportionately important:
`GObjPC_GainExpAndLevel`, `GObjPC_GiveExp` and `Char_GetLevel` are all in that
population, and each one cost a manual vtable read to find (slots 92, 421, 73).

Finding the tables needs no RTTI, which is just as well — this binary's is
stripped (`RttiProbe.java`: 1,871 type descriptors, **zero** referenced). A C++
vtable is a run of consecutive pointers into executable code sitting in
read-only data, and that shape is unmistakable.

Two outputs, kept apart by how certain they are:

- **A plate comment** naming the table and slot, on every function found in one
  (2,999 server + 2,226 client). This is the fact the project has had to
  re-derive by hand four times; it turns "which slot is this?" into a grep.
- **A `module` namespace**, only when the table's own slots vote for one: at
  least `minAgree` already-attributed slots, and two thirds of them agreeing. A
  class's vtable is mostly its own methods, so a clear majority is evidence; a
  scattering is inherited base-class slots and earns nothing. **In practice this
  returns almost nothing today** (13 server, 55 client) because too few vtable
  slots are pre-attributed to vote with — it will pay off as other levers seed
  the namespaces, not before.

The comment says **"pointer table"**, not "vtable", because the shape alone
cannot tell a vtable from an array of callbacks. That distinction does not
matter for finding the code, and overstating it would be the usual mistake.

## InterpolateModules.java `[apply] [maxGap]`

MSVC emits a translation unit's functions contiguously, so if the nearest
attributed function *below* an unknown one and the nearest *above* it are both
in module M, the unknown one is almost certainly M too. The whole risk sits in
how far "nearest" is allowed to reach, which is what `maxGap` controls.

**A stronger version was measured and rejected**, and it is worth knowing why
before anyone reinvents it. Taking each module's full address span and claiming
everything inside looks attractive — 1,781 server functions — until you see
which: the biggest contributor was `RefInstanceGenerator`, **16 confirmed
members spanning 1,207 functions**. A span being "clean" (no *other* module has
a member inside) means almost nothing when 97% of functions are unattributed.
That is extrapolation across a void. This script interpolates between near
neighbours instead, a much smaller claim.

`maxGap` is the honesty dial: 3 attributes 218 server / 1,068 client; 8 would
take 478 / 2,549, and each step out weakens the claim. Default 3.

Every touched function records **why** in a plate comment — both bracketing
addresses, the module, and the gap size — and says plainly that it is an
inference, unlike the `__FILE__` asserts that seeded it.

## The compounding order

These levers feed each other, so a full pass runs them in this order:

1. `NamespaceFromSourceFile` — the `__FILE__` seeds (facts).
2. `LabelFromUIStrings` — authored UI ids (facts, client only).
3. `InterpolateModules` — fill small gaps between same-module neighbours.
4. `PropagateModules` — call-graph unanimity, now with a richer seed set.
5. `VtableAttribute` — let the vtables vote; **this one is last and wants
   re-running after every other lever**, since it is the only step that can
   reach virtuals and it needs attributed slots to vote with.
6. `CodeCensus` then `DecompAll` — measure, then render to C.

`re_pass.sh` runs the two binaries as parallel lanes; only the steps *within* a
lane are ordered.

## NameDBBinders.java `[apply]`

**The largest single naming return in this project, and the game's schema.** The
server binds every persisted column to a struct offset through one helper, in a
fixed shape — `FUN_00401fc0("Strength", 8)` for the name, then the offset, the
type, and the bind call. **60 functions call that helper, one per table**, and
this names them all `DB_Bind_<TABLE>` with the columns written into each plate
comment. 55 named in a single pass.

It is self-validating, which almost nothing here is: the `_CHAR` binder
reproduces `Strength` 0x74, `Intellect` 0x76, `CurLevel` 0x65 and
`RemainSkillPoint` 0x80 — four offsets derived earlier by unrelated routes, all
exact. A map that gets four known answers right can be trusted for the other 34.

Beyond naming, it hands over the real game's **persisted data model**: `_CHAR`,
`_ITEMS`, `_CHARQUEST`, `_CHARSKILL`, `_CHARSKILLMASTERY`, `_INVENTORY`,
`_CHEST`, `_GUILD*`, `_Friend`, `_Memo`, the siege and training-camp families,
and the log tables. See `docs/RE_COMPLETION.md` for the schemas that matter.

## ValidateNames.java `[maxReport]`

**Run this after every bulk naming pass.** Naming from a pattern is this
project's highest-leverage technique and its most dangerous one, for the same
reason: one inference is applied hundreds of times, and the per-name evidence is
never re-read.

That is not hypothetical. The opcode-tree pass produced 29 names and **8 were
wrong** — a 28% error rate. The worst was `FUN_00964b60`, the assert helper with
**10,357 call sites**, labelled `MsgHandler_7d1b`; it sat wrong for three ticks
and surfaced only because an unrelated read showed `MsgHandler_7d1b()` being
called *as an assert*, which reads as nonsense.

Each bulk pass has a property its members must have that is **independent of how
they were named**:

| prefix | independent check |
|---|---|
| `DB_Bind_*` | must call the column-bind helper `0x00862e40` |
| `MsgHandler_*` | must have few callers — a handler has ~2 |
| `RefParse_*` | must read ≥3 sequential refdata tokens |

Hand-named functions are not checked: they were reasoned about one at a time,
which is exactly what bulk naming skips.

It reports rather than fixes — a violation means the evidence needs re-reading,
not that the name is automatically wrong. All eight bad opcode names turned out
to be **singleton accessors** (`if (g == 0) Assert(); return g;`) and **message
buffer readers**, and are now named as such.

## ValidateAttribution.java `[maxReport]`

The companion to `ValidateNames.java`, for the *attribution* passes rather than
the naming ones. `InterpolateModules` assigns a module from **address
adjacency**; the **call graph** is an independent signal, because a function
really in module M usually calls or is called by other M functions.

Measured at `maxGap = 3`: **79.6% agree** on the server and **72.9%** on the
client, with genuine suspects (several dissenting neighbours, none agreeing) at
**0.7%** and **3.3%**. The heuristic holds.

Note what "isolated" means — ~16% have no attributed neighbour either way, so
the call graph says nothing about them. That is not a failure, it is the check
declining to have an opinion, and it is reported separately rather than counted
as agreement.

**This validates the gap size in use.** Raising `maxGap` invalidates the
measurement; re-run after any change.

## `RttiRebuild.java` — the class names, from the binary's own RTTI

This lever was recorded closed ("impossible, not merely hard") on the strength
of a probe that asked the wrong question. An MSVC `TypeDescriptor` is

    struct TypeDescriptor { void *pVFTable; void *spare; char name[]; };

so `.?AVCGObjPC@@` lives at **+8 inside** the descriptor while the complete
object locator points at its **start**. Counting references to the *string*
returns zero no matter how intact the chain is. Walk
`vftable[-1] → COL → TypeDescriptor` and it is all there: **1,211 classes on
the client, 1,939 on the server**.

Two traps, both of which make the result look stripped when it is not:

- **Enumerate the descriptors from raw bytes.** Ghidra had typed only 1,088 of
  the client's 1,223 as strings, and a missed descriptor costs its class, its
  vftable and every slot in it.
- **Walk slots while the word points into executable memory**, not while
  `getFunctionAt` succeeds. Ghidra's function coverage is not the binary's;
  using it as the loop condition cut tables to 1.4 slots on average. The COL
  pointer between two tables is `.rdata`, so the walk still stops correctly.

`probe <hex>` prints one table against known slots. On `0x00af59fc` it returns
class `CGObjPC` with slot 73 `Char_GetLevel`, 92 `GObjPC_GainExpAndLevel`, 93
`GObjPC_AddSkillPoints`, 421 `GObjPC_GiveExp`, ending at 427 slots — four
hand-derived facts reproduced by a mechanism that knew none of them.

`apply` names a function only where **exactly one** class claims it, and only
over a blank `FUN_`; an inherited implementation appears in every derived
class's table, so anything shared gets a comment listing all its claims instead
of a confident wrong name.

Run it **first** in the compounding order below — it is a fact source, like the
`__FILE__` seeds, and everything downstream feeds on its namespaces.

## `RttiBases.java` — the hierarchy, and the functions Ghidra never reached

`RttiRebuild` walks `vftable[-1] → COL → TypeDescriptor` and learns what a
class is **called**. The COL's other pointer says what it **is**:
`COL+0x10` → `ClassHierarchyDescriptor`, `+0x08` base count, `+0x0C` base
array, each `BaseClassDescriptor` pointing at a `TypeDescriptor` from offset
**0**. That offset is why those sites were rejected as "bad COL signature" —
they were the other half of the chain, not noise.

Element 0 of the base array is the class itself, so 1..n-1 are its bases in
MSVC's own layout order. **1,939 server / 1,211 client classes get a chain.**

`create` also defines a function at every vftable slot target Ghidra never
reached — 6,799 of them. A slot target *is* a function entry; Ghidra finds
functions by following calls and a virtual has no direct caller. This is the
stronger version of what `VtableAttribute` works around, because a defined
function gets **decompiled into the dumps**. Run the census first (no
argument): it separates targets that are already entries, ones sitting inside
another function (left alone — splitting a correct body is worse than missing
one), ones merely undisassembled, and ones that will not disassemble at all.

**Re-dump after `create`.** The dumps are the artifact every later grep reads,
and 6,799 new function bodies are not in them until you rebuild.

## `NameVtableSlotsFromAsserts.java` — let the base class name the slot

This is the lever that found berserk, generalised. `IGObj::UpdateHwanLevel`'s
base implementation is a stub that does nothing but log its own name:

    "## Illegal ##  IGObj::UpdateHwanLevel TypeID: %u"

RTTI says that stub is slot 197. Those two facts together do not name one
function — they name **slot 197 in every class that inherits it**.

248 such `(class, slot, method)` triples are in the server's own strings, in the
game's own spelling: `CGStorageOP::PushItem`,
`CGStorageOP::RandomSelectNonEmptySlotForDeathPenalty`,
`CGItemCOSSummoner::SetEngagedCOSforOpenMarket`, `IGObj::GetParam`.

**Validated against three facts it did not produce**: `IGObj slot 65 GetParam`
(this project derived vtable offset 0x104 = GetParam by hand; 0x104/4 = 65),
`IGObj slot 197 UpdateHwanLevel` (the berserk work), and `IGObj slot 74
GetMaxLevel` sitting immediately after the hand-derived slot 73 `Char_GetLevel`.

Two guards, both of which earned their place:

- **The string's class is the authority.** The seed is `(class named in the
  string, slot)` and propagates only to vtables whose class is that class or has
  it in its base chain. Slot numbers mean nothing across unrelated hierarchies —
  `CGStorageOP` slot 38 and `CGObjChar` slot 38 are different methods.
- **`Class::member` is not a method.** The client's `"CObjChild::m_pGfxDevice is
  null"` would otherwise seed slot 15 of the root of the entire UI hierarchy;
  that one string accounted for **477 of the client's 484** candidates. Names
  starting `m_`, and ALL_CAPS tails, are rejected.

Count nameable functions as **distinct entries**, not `(seed, class)` pairs: an
inherited implementation is one function reached through every derived table, so
the pair count runs about thirteen times higher than reality.

Run it after `RttiRebuild`, before the interpolate/propagate/vtable chain.

## Greps that silently exclude a subset

Two false negatives in two consecutive sessions, both from a pattern that looked
exhaustive and was not. Recording the shape because it is now a pattern rather
than an incident, and because **a false negative here looks exactly like a
settled question** — an absent value reads as "this does not exist" and gets
written into the docs as a closed item.

- **`grep '== 0x'` over a decompiled switch misses every `!=` branch.** MSVC
  emits a dispatch as a binary-search tree, and the leaves alternate between
  equality and inequality tests. Harvesting the skill param-code vocabulary this
  way dropped `'ar'` — which was the single code the question at hand turned on.
- **`\(0x[0-9a-f]+\)` misses small numbers.** Ghidra prints them in decimal, so
  a census of `GetParam(...)` call sites found nothing for params 1–9 — including
  params 5 and 7, the two mitigation terms this project had already recovered
  and could have used as a self-check.

The cheap defence is to **include a known-present case in every census** and
check the pattern finds it before trusting what it does not find. Params 5 and 7
were right there; the run that missed them should have failed loudly.

Related: multi-char constants worked out by hand are wrong often enough to
matter (`'defr'` is 1684366962, not 1684366450 — a slip that reported 273 real
skills as zero). Compute them in a script, not in your head.

## mislabelled_owners.py `[dumpDir]`

Finds functions whose name credits the **wrong class**, and needs no Ghidra —
it reads the dump's own headers.

A vtable slot implemented once and shared by a hierarchy appears in many
classes' vtables. The RTTI walk that names it reaches one of them first and
labels the function with that class; when the one it reached is a DERIVED class,
the name misleads. `CGObjCOS_Summoned::EnterWorld` is not a summon's function —
it is the `CGObjChar` implementation every character shares, and a reader
looking for player logic greps straight past it. **A wrong name is worse than
`FUN_`.**

The test uses only what the dump records: a function's header carries both
`RTTI: reached as A slot N, B slot N, …` and `RTTI hierarchy: Derived : … :
Base`, so if the class in the name derives from another class that also reaches
the function, the name credits a descendant of the real owner.

	python3 mislabelled_owners.py /var/tmp/decomp_server
	python3 mislabelled_owners.py /var/tmp/decomp_client

As of 2026-09-15: **48 of 331** in the server, **69 of 93** in the client. The
server's matter more — they include real names (`EnterWorld`, `ConsumeHpMp`,
`GetCharName`, `GetGender`) rather than a wrong namespace on an unnamed method.

**What it cannot tell you** is which class DECLARES the slot. The most ancestral
class in the RTTI list is a lower bound; the declaring class may be further up
and only an assert string will say so — `SetBodyMode` reaches `CGObjChar` in the
list while its assert names `IGObj`. Read the output as "this name is wrong",
never as "this is the name".

**Two parsing traps, both hit on the first pass.** The class is the component
*before* the method (`std::bad_alloc::vslot_000` is class `bad_alloc`, not
`std`), and a function whose RTTI lists a single class cannot have this problem
at all. Ignoring either turns 48 findings into 906.

## Censusing a vtable slot: resolve the RECEIVER's class

A call like `(**(code **)(*x + 0x170))(...)` means nothing until you know what
`x` is. The same offset is a different function in every unrelated hierarchy, so
a census that greps `+ 0xNNN))(` across the dump silently mixes them.

This has produced a wrong result three times in this project:

- **`0x104`** is `GetParam` on a character and a three-argument something-else on
  quest classes. ~100 quest hits nearly swamped a census of which params the
  engine reads.
- **`0x318`** (slot 198) is one shared implementation reaching seventeen classes;
  the dump indexes it under `CGObjCOS_Summoned`, which made a player's berserk
  bonus look unreachable.
- **`0x170`** is `GObjPC_GainExpAndLevel` on a character and an `IQuest` virtual
  on `CQNO_*`. Eight quest call sites were listed as experience grants when they
  are `__thiscall` on `this`, a quest.

**The check, in order of strength:**

1. The receiver expression. `(*param_1 + 0x170)` inside a
   `__thiscall Foo::bar(Foo *param_1, …)` is a call on `this` — the enclosing
   class's own hierarchy, never another's.
2. The dump's `RTTI hierarchy:` line for the enclosing function, which names the
   chain the binary itself recorded.
3. The enclosing function's namespace, which is the weakest: a function in
   `GObjPC` may call the slot on a char it was passed, and a virtual shared by a
   hierarchy is indexed under only one of its classes.

A census that reports a count without saying which classes it counted has not
answered the question it looks like it answered.


## `dump_gaps.py` — what the dump cannot see

**Run this before publishing any conclusion that rests on an enumeration.**

Every census in this project greps `/var/tmp/decomp_server`: "who calls X", "how
many call sites are there", "who writes offset Y". Those are censuses over *what
Ghidra recovered*, not over the binary — and the difference is not small:

| | bytes | share |
|---|---|---|
| `.text` | 7,176,192 | |
| indexed by the dump | 5,936,050 | 82.7% |
| **invisible** | **1,242,362** | **17.3%** |

Most of that is CRT and template code, but **6.1% of the game-logic band
(0x401000-0x700000) is invisible too — 145 real-code gaps, about 30 KB.**

This is not hypothetical. On 2026-09-16 an enumeration found eleven
`SetBodyMode` call sites, none giving berserk a duration, and shipped the
conclusion "berserk has no timer". The berserk activation handler is at
`0x00515bfd`, inside a gap; it was the twelfth call site, and berserk lasts 60
seconds.

```
python3 dump_gaps.py                        # the gap map
python3 dump_gaps.py --calls 4a9fc0,4b3510  # do invisible gaps call these?
```

`--calls` answers the only question that matters at publish time. If it prints
"the enumeration is safe", the dump saw everything that calls those functions.
If it names a gap, the enumeration is incomplete and `objdump` is the only way
to finish it.

Two findings from its first run, both worth keeping:

- The pool-writer, exp-grant, mastery and chance-roll enumerations are **safe** —
  no invisible code calls any of them.
- A 4.3 KB invisible function at `0x004a4570` writes params 178-181. It does not
  overturn `berserk`'s completeness note, because it writes them at
  `slot 2, ctx 5` and removes them at the same ctx — a keyed modifier, not a
  baseline — but it did force that note to be restated so it rests on the param
  registry's defaults rather than on having seen every writer.
