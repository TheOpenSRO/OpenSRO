# Propagating vtable-slot names, and why it yields eleven and not three hundred

**Measured 2026-09-18.** The largest single block of unnamed functions is not `FUN_*` but
`vslot_NNN`: **2,757 in the server and 4,350 in the client**, functions whose class is known
from RTTI but whose slot has no meaning attached. The obvious lever is to propagate: if one
class has slot *k* named, give that name to every sibling's `vslot_k`.

Done carelessly it produces hundreds of names, and they are wrong. Two separate mechanisms
produce the wrongness, and both had to be closed before the result was usable.

## Rooting at the RTTI root is unsound

The first attempt grouped classes into families by walking `RTTI hierarchy:` comments up to
the root, then propagated within a family. It offered **312** names — and the families were
garbage, because **every class roots at `CBase`**. Slot 2 of `CGObj` is `GetJID`, so the pass
happily offered `GetJID` to `CRgnTerrain`, `CMaintainer` and `CPeerProcessOverlapped`. A slot
index only means the same thing inside one subtree, and the root is not a subtree.

The structural replacement: propagate between two vtables only when they hold the **same
function address at the same index, eight or more times**. Identical addresses at identical
indices is proof of a shared inherited table, so a slot where the two differ is two overrides
of one virtual.

## Identical code folding poisons it anyway

That cut 312 to **101**, and the survivors were still wrong: `SaveCurPosAsLastTelPosition`
appeared at slots 15, 16, 22, 215 and 305 across `CServerApp`, `CQEV_GUILD_SUPPORT`, `CGObj`
and `CGItem`. One folded body occupies many unrelated virtual slots, and its name — recovered
from a single class's assert — travels to all of them. The project's own vtable tooling
already warns "FOLDED, do not name after one class"; this is that warning as a number.

Excluding addresses that sit at **more than two distinct slot indices** (27 of them) and
`thunk_*` names leaves **11**.

## What survived

	slot 317  CanBeEquipedAt              4 sibling item classes, from CGItemEquip
	slot 400  UseItem                     4 sibling COS classes, from CGObjCOS_Pet
	slot 395  CanBeAttackedBy             from CGObjSiegeObject
	slot 327  SetEngagedCOSforOpenMarket  from CGItemCOSSummoner
	slot 9    BlessItem                   from CEnchant_EnchantMagicStone

Applied 11, failed 0. Class-prefixed source names (`CGItemCOSSummoner__SetEngagedCOS…`) are
reduced to the bare method, because the prefix names the class the name was *read from*, not
the class receiving it.

## The conclusion worth keeping

**This lever is close to exhausted, and the 7,107 `vslot_` functions are not reachable through
it.** A slot's meaning has to come from evidence about that slot — an assert, a log string, a
call site — not from a sibling. The number to remember is 312 → 101 → 11: two filters, each
removing an order of magnitude, and the residue is what was ever really there.
