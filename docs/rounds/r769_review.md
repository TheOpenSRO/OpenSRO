# Round 769 review: the worn plus and blue options in stats and combat

Reviewer: independent, adversarial. No files in /root/srrevamp were edited.

## Verdict

**The direction is right. Fix F1 to F3 before this lands.**

The RE placement is correct everywhere I spot-checked: the plus formula, the order of 'hr'/'er',
'cri'/'bri' replacing the item's entry, crit variance group 6, broken items excluded, and evasion.
The integration is incomplete, though:

- **F1:** the SQL character store's two HP refills ignore the bonus, so a level-up tells the client
  one HP and stores another.
- **F2:** stored HP is never clamped when gear comes off, and the panel hides it. Players can bank
  extra HP this way.
- **F3:** a transient store error caches a zero bonus.

Gate (MEASURED): `go build ./... && go vet ./...` passes, and so does the targeted test run.
`internal/character` reports "[no tests to run]", so nothing in the gate exercises `BonusOf`
directly. The full `go test -count=1 ./...` also passes (exit 0, no FAIL). It ran without a
database, so the SQL stores were not exercised.

## RE spot-checks (READ on the box, 2026-10-11)

- **Crit group 6: confirmed.** `mov esi,0x6` at 0x4965ce, then `call 0x495d10`, then the
  interpolation `fstp [ebx+0x1dc]` at 0x4965f4.
- **'cri' / 'bri': confirmed.** Stat_ApplyTaggedModifier 0x498690 computes 'cri' as
  `ROUND(broken ? 0 : item+0x1dc) + v` into param 12, and 'bri' the same over +0x1a4. 'hp' and
  'hpa' go to param 3, 'evcr' to 57 and 'evbl' to 56. None of these branches gates on broken.
- **Broken items: confirmed, but the cited mechanism is imprecise.**
  - SetParamKeeperForMagicOpt 0x66b180 has no broken check.
  - What excludes a broken item is CGObjPC::ChangeItemDurability 0x4e7100. On break it calls
    `RemoveParamKeeperItemEntry(pc,0)` and does not re-publish. On repair it calls Remove and then
    PublishEquipItemParams.
  - PublishEquipItemParams 0x4e3760 runs the option OPs (FUN_004992e0) only when
    Char_PublishCombatStats returns nonzero.
  - So "the publisher zeroes a broken item's params" is true in effect; the citation should be
    0x4e7100 / 0x4e3760.
- **Requirements gate: not modelled.** PublishEquipItemParams first gates the whole item, white
  stats and options together, on CGItemEquip::CheckEquipRequirements 0x4919e0. OpenSRO counts
  options whatever the requirements say. This is harmless only while a worn item can never fail its
  requirements. Mark it OPEN.

## Findings

### F1 (High): the SQL HP refills ignore the bonus; Mem and SQL diverge

**Where:**
- `internal/character/sqlstore.go:367` (RespawnHP) and `:386` (ResetHP) compute
  `ROUND(str*10*1.02^(level-1))` in SQL, with base Str and no 'str'/'hp' bonus.
- `memstore.go:232/245` use `c.MaxHP()`, which includes the bonus.

**Consequences:**
- `killshare.go:285-287` level-up: `ResetHP` stores the chain without the bonus, then sends
  `out.hp = MaxHPFor(newStr+bonus.Str)+bonus.HP`. On SQL the client is told full HP that the row
  does not hold.
- GM `/heal` (`gm.go:852-864`) prints "HP x/MaxHP" with x below max.
- The respawn after death gives 40% of the wrong maximum.
- The tests run on the MemStore, which hides all of this.

**Fix:** make ResetHP/RespawnHP take the max (or the bonus) from the caller, the way `Heal(amount,
maxHP)` does, or have them compute it through `character.BonusOf`.

### F2 (Medium-High): HP above the new max is never clamped; the panel hides it

**Where:**
- `stats.go:314` sends `min(HP, MaxHP())`. Its comment says the stored HP "is clamped by the next
  heal or regeneration". That is false for regeneration: `regen.go:158/170` skips HP when
  `c.HP >= maxHP`.

**Consequences:**
- Unequipping +HP gear, swapping it (`handleEquip`), or having it break leaves stored HP above max
  indefinitely.
- Combat damages that stored HP, the world entry (`world.go:1642`) sends it, and so do the party
  bars (`party.go:570`).
- That is an HP-banking exploit, and the client sees a panel value different from the 0x3057
  remaining HP.
- MP does not have this problem: `mana.Tracker.Current` clamps.

**Fix:** clamp the stored HP to `MaxHP()` right after `InvalidateBonus` in unequip, equip-swap and
break, through a store-side clamp (`LEAST(hp, $max)`). Then drop the display-only `min`. Whether
retail clamps there is OPEN; label it OURS.

### F3 (Medium): a transient eq.Get error caches a zero bonus

**Where:** `equipstats.go:113-116`. On error, `equipBonus` returns an empty Bonus, and `BonusOf`
(`character.go:563-572`) caches it until the next equip change. The same happens if
`magicOptions` is nil at first read.

**Consequence:** one DB hiccup removes a character's Str/HP gear until they re-equip.

**Fix:** let the source return `(Bonus, ok)` and don't cache on `!ok`.

### F4 (Medium): missed TotalStr / TotalInt / MaxHP sites

- `useitem.go:1096`: potionRestore is passed `owned.Str` / `owned.Int`. Its own READ comment
  (useitem.go:220-249) says the engine uses `GetParam(1)` / `(2)`, which is now the total. The line
  "OpenSRO models no Str/Int bonuses" (useitem.go:246) is now false. Absolute potions under-heal for
  geared players.
- `gm.go:837/842`: `/level` refills MP with `MaxMPFor(newInt, want)` and prints HP/MP without the
  bonus.
- `lobbyhandler.go:616` sends MaxMP with the bonus but base Str/Int (`:623`). That is mixed. Low.

### F5 (Medium, performance): uncached eq.Get in the hottest paths

- `playerEvadeBlock` / `playerEvadeCrit` call `eq.Get` and rebuild `optionsOf` on every blow:
  - per hit inside performAttack's multi-hit loop (combat.go:1254/1276);
  - on every monster strike, twice when a wall is up (monsterstrike.go:373/398);
  - twice per duel blow.
- On the SQL equipment store each of these is a query, and they add to the existing
  `attackerCritical` / `defenderBlock` / `defenderArmor` reads.
- **Fix:** fold Evbl/Evcr (pre-clamped) into the cached `character.Bonus`.
- Also:
  - `MaxHP()` takes the global `bonusMu` twice per call (TotalStr + `.HP`), and every regen tick
    does that four times per player.
  - On a cache miss the source runs a query under `killLock` (regen.go:140-152) with
    `context.Background()` (no deadline).
  - Use an RWMutex or `sync.Map`, and fetch the Bonus once per call.

### F6 (Low): the cache and registry

- **Lock order and generation counter:** correct (invalidate-after-mutate, gen checked before
  insert).
- **SetBonusSource:** does not bump the generations, so an in-flight compute from the old source
  can be cached against the new one. Boot and tests only.
- **Unbounded maps:** `bonusCache` and `bonusGen` never shrink. Every character listed in a lobby
  is cached (lobbyhandler `MaxMP()`).
- **Leak to another character:** ids are unique, so I found no cross-character leak. Session and
  logout need nothing.
- **Mutation paths covered:** equip, unequip, GM `/item worn`, GM `/durability`, wear-break and
  repair. Alchemy (bag slots only, alchemy.go:362-395), trade and pcrecord do not touch worn items.
  I found no missed mutation path.
- **Lock hierarchy:** `MemStore.ResetHP` / `RespawnHP` now call `BonusOf` and then `eq.Get` under
  the character store's mutex. That creates a chars → equipment lock order. It is safe today; note
  it.

### F7 (Low): smaller correctness notes

- **Stats panel:** `weaponRanges` (stats.go:229-241) has no broken-weapon check. A broken weapon's
  range now shows its plus as well. Combat (combat.go:1544) uses fist damage instead, so the two
  disagree.
- **Untracked shield 'bri':** uses `int(BlockRatioMin)` (truncation), but the RE says `round(...)`.
  Equal on integer data.
- **'cri' / 'bri' on other kinds:** only the weapon's 'cri' and the shield's 'bri' are read. The
  RE says "per item, then summed over items". Whether retail ever puts 'cri' on another kind was
  not checked: OPEN.
- **Two "effective plus" helpers:** `equipment.Equipped.EffectivePlus()` (OptLevel+AdvElixir, the
  wire byte) and `session.effectivePlus` (+ 'rein') share a name and differ. Rename one, or document
  the difference.
- **Set-item opt-level bonus:** ApplySetItemOptLevel2ThisGroup's `extra` byte is omitted, but the
  "Not built" list does not mention it.

### F8 (Medium): the tests claim more than they test

TestWornPlusAndOptionsCount is a good end-to-end check, but:

- **Crit variance never exercised:** `CriticalMin == CriticalMax == 3`, so group 6 is untested.
- **No 'rein' or advanced-elixir case:** the effective plus is only ever OptLevel.
- **No broken item:** not for the bonus, the crit, the evasion, the defence or the parry.
- **No 'evbl', 'int' or 'mp' case,** and no magical defence plus.
- **Invalidation tested by hand:** the test calls `InvalidateBonus` itself, so a handler that
  forgets to invalidate passes.
- **No unit tests:** nothing for `BonusOf` gen/cache, nothing in `internal/character`, and none
  for the SQL HP refills (F1).

WORLD_ISSUES' "It checks every stat above" overstates this. The variance-group-6 claim and the
effective-plus claim are both untested.

### F9 (Low): labels

- **Broken items:** "the publisher zeroes a broken item's params" (equipstats.go:19-20,
  item_magic_options.md) should cite ChangeItemDurability 0x4e7100's remove-without-republish and
  PublishEquipItemParams 0x4e3760's gate.
- **Stale comment:** `stats.go:311-313` claims regeneration clamps (false, see F2), labelled OURS.
- **'rein' value:** "MEASURED: level 1 gives 1, level 2 gives 2" (equipstats.go:96) is fine.
  Its "column 9" is `Params[1]`, which I verified against magicopt.Row (columns 8..11).
- **Evasion comment:** the retired-tripwire text and the evasion.go table are accurate.

## Resolution (main session)

Every finding was taken in round 769:
- **F1:** the SQL `ResetHP` / `RespawnHP` add the worn items' bonus (`character.BonusOf`).
- **F2:** `clampHP` after unequip, swap, a worn piece breaking in combat, and the GM `/item worn`
  and `/durability` edits (OURS). MemStore's `Heal` now clamps the way SQL's `LEAST` does.
- **F3:** the bonus source returns `(Bonus, ok)`; a failed read is not cached. Test.
- **F4:** potions use `TotalStr` / `TotalInt`, `/level` uses `MaxHPWith` / `MaxMPWith`, and the
  lobby list sends the totals.
- **F5:** the evasion sums live in the cached `character.Bonus`; the registry is an RWMutex;
  `MaxHP` calls `BonusOf` once.
- **F6:** `SetBonusSource` bumps an epoch the cache checks.
- **F7:**
  - `weaponRanges` treats a broken weapon as bare hands;
  - the untracked shield rounds;
  - every worn item's 'cri' / 'bri' is summed;
  - `effectivePlus` is renamed `wornPlus`;
  - the set-item bonus is listed as not built.
- **F8:** tests for the critical's group 6, 'rein', a broken piece, 'int' / 'mp' / 'evbl', the
  magical defence's plus, the failed read, and the unequip handler's clamp.
- **F9:** the broken-item citations name 0x4e7100 and 0x4e3760; the stats.go clamp comment is
  corrected; the requirement gate is OPEN.
