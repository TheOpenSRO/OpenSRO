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
