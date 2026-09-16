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
