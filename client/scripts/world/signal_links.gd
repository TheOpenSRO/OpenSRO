extends RefCounted
class_name SignalLinks

## Round 866 (lane AX, the guardian's crash): the connections a world-owned
## flow (a RefCounted World3D makes: AcademyFlow, UnionWorld, SpecialtyFlow)
## makes to signals that outlive the world -- NetClient's stores, an autoload
## -- kept so the world can cut them when it leaves the tree (`cut`).
##
## Why: a lambda that uses `self` holds a strong reference to its RefCounted
## (GDScript's self lambda keeps a Ref), so a flow connected to an autoload's
## signal through one is never freed. After a world re-entry (back to the
## character select and in again) the old flow stayed connected, with its
## `hud` and `world` freed: MEASURED in a player's v0.1.638 log, every
## academy reply printed twice after the re-entry. Its next call on the freed
## HUD is a use after free. MEASURED: after one re-entry the guardian's
## 0x747E question killed the v0.1.638 export (SIGSEGV, nothing in its log)
## and the editor build too (signal 11, after a "previously freed" script
## error from the old flow's academy line); a run that enters the world once
## has one flow and never shows it.

var _links: Array = []

## Connects `callable` to `sig` and remembers the pair.
func link(sig: Signal, callable: Callable) -> void:
	sig.connect(callable)
	_links.append([sig, callable])

## Disconnects every remembered pair still connected; the flow's lambdas
## (and with them the reference cycle that kept it alive) go with them.
func cut() -> void:
	for pair in _links:
		var sig: Signal = pair[0]
		var callable: Callable = pair[1]
		if sig.get_object() != null and sig.is_connected(callable):
			sig.disconnect(callable)
	_links.clear()

func count() -> int:
	return _links.size()
