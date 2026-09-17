# `IGObj` vtable slots, recovered from the engine's own error strings

The server's base classes implement most virtuals as a **stub that logs and
returns**, so a derived class that forgets to override one is caught at runtime:

	CGameServer::FUN_00936640(0x2000000,
	    "## Illegal ## IGObj::SetBodyMode TypeID: %u", ...);

Each of those 213 strings names its method in the binary's own words, and
finding the stub's address in `.rdata` gives its slot — a stub sits at the same
index in every vtable of the hierarchy. 202 resolve to exactly one slot and 7
sit at two (see below); **209 `IGObj` slots** are listed here.

Regenerate with `client/tools/ghidra/recover_vtable_slots.py`, which asserts two
slots this project had recovered **independently** and exits non-zero if the
arithmetic breaks.

## Why the slot numbers are trustworthy

The vtable base is found by walking backwards from an entry until a dword stops
being a `.text` pointer — the slot before a vtable holds its RTTI locator. That
is a heuristic, so it is tested rather than assumed:

- The `SetBodyMode` stub appears in **14 different vtables**, and this puts it at
  slot **198 in all 14** — the slot recovered earlier from the berserk
  activation handler, with no reference to any of this.
- Five further slots each land on a name that *explains a call site this project
  had been reading blind*:

| offset | slot | name | what the project had observed |
|---|---|---|---|
| `0x1c` | 7 | `IGObj::IsPC` | tested for "is not a PC" in the damage path |
| `0x28` | 10 | `IGObj::IsMonster` | called by both raw-damage builders |
| `0xf8` | 62 | `IGObj::GetLifeState` | the guard opening **both** mitigation formulas — so the guard means *both parties must be alive* |
| `0xfc` | 63 | `IGObj::GetMotionState` | tested `== 8` |
| `0x100` | 64 | `IGObj::GetBodyMode` | tested `== 1`; the berserk handler's own `if (GetBodyMode() == 1)` |
| `0x104` | 65 | **`IGObj::GetParam`** | the param getter cited all through the damage pipeline |

`0x104` is the single most-referenced unnamed virtual in this project's comments.

**A correction this forces.** `berserk.go` called slot 64 `CGObjChar::IsBerserk`.
The binary calls it `GetBodyMode`, and `SetBodyMode` at 198 is its twin. The
implementation at `0x004aa5b0` does return "is the body mode 1", which is why
the name looked right — but it was this project's name, not the game's.

## What this does NOT recover

Virtuals with **no base-class stub** leave no string and never appear here. That
includes all four vtable calls in the cast-requirement check — slots 353, 372,
399 and 400.

**Three of the four have since been given a MEANING by a different lever**
(2026-09-16), which is worth recording because it shows what to reach for when
the stub harvest comes up empty. `FUN_0058d480` returns error `0x300f` when slot
`0x5d0` (372), `0x63c` (399) or `0x640` (400) returns 0, and the client names
`0x300f` **`UIIT_SKILL_USE_FAIL_BROKEN_WEAPON`** (docs/protocol/error_codes.md).
So all three are **serviceability checks**: a cast requirement wants the item
present *and* not broken, and these are the second half. Their method NAMES are
still unrecovered — an error code gives meaning, not a symbol — and slot 353
remains unknown on both counts.

### Seven names sit at two slots, and that is not ambiguity

**Corrected 2026-09-16.** An earlier version of this file called these ambiguous
and guessed they were "two hierarchies whose layouts differ by an inserted
virtual". Reading the *implementations* at both slots settles it, and the answer
is not one thing but two — scoped to the vtables that actually contain each
method's stub, because slot 66 means something different in each of the ~274
vtables in this binary:

| name | slots | what the implementations show |
|---|---|---|
| `GetCurHP` | 66, 68 | the same function at both **in the vtables this was measured over** — but see the correction below; it is not universal |
| `GetCurMP` | 67, 69 | same caveat |

**CORRECTION 2026-09-16: 68 and 69 are not always duplicates of 66 and 67.**
`CGObjCOS_Summoned` has `GetCurHP` (`0x004aa5e0`) at slot 66 and a *different*
function (`0x004a6830`) at slot 68 — and that one reads a ParamKeeper param
(`FUN_004b3740` → `ParamKeeper_EnsureParam` + `Param_GetValue`) rather than the
object's stored HP. **Slot 68 is the computed MAXIMUM, not the current value.**
`CGItemMonsterCapsule` does have the same function at both, which is how the
original measurement came out the way it did.

This is not a footnote. `GObjPC_SetLevel` computes its level-up heal as
`vslot(0x110) − vslot(0x108)`; under the "both are GetCurHP" reading that
difference is identically zero and the engine would refill nothing. Under the
corrected reading it is `MaxHP − CurHP`, a full top-up — which is what the
engine actually does. **A slot identity taken as universal produced exactly the
wrong answer about a game mechanic**, and the thing that caught it was noticing
that the zero reading made four virtual calls into dead code.
| `ExpandInventory` | 173, 174 | **different** functions — two distinct methods whose stubs share one log string, i.e. overloads (30 vtables) |
| `IsAccomplishedCollectionBook_Theme` | 207, 208 | overloads (30 vtables) |
| `IsRegisteredCollectionBook_Item` | 209, 210 | overloads (30 vtables) |
| `RaiseEvent` | 80, 81 | overloads |
| `GetWorldLayerEventHandlers` | 182, 188 | **mixed** — same in 1 vtable, different in 19. Reported as mixed rather than forced into either box. |

Either way both slots are real, so both are in the table below.

The `IGOBJ::` spelling (six methods, all Temple/AP-related) is the engine's own
inconsistent capitalisation, kept verbatim.

## How much of the game this reads

Joined against every `(**(code **)(*x + 0xNN))` call site in the server dump:
**15,249 of 17,207 vtable call sites (88.6%) now resolve to a name**, across 170
of the 353 distinct offsets called. The most-called are `GetGameID` (1,181),
`GetQuestStatus` (1,056), `GetQuestData` (609), `SaveQuestNow` (578),
`GetWorldID` (561) and `IsPC` (532).

In the combat and damage shards specifically the top calls are `IsPC` (84),
`GetParam` (56), `GetLifeState` (34), `GetLevel` (34) and `IsMonster` (29) —
which is a fair description of what a damage routine does, and a sanity check on
the names.

## Applying the slots to their implementations — already done

A slot name should also name the function sitting in that slot of every derived
vtable. Measured: the 209 slots reach **275 distinct implementation addresses**
across the 14 IGObj-family vtables — not 14x209, because most virtuals have one
implementation shared by every derived class.

**271 of those 275 are already named.** The multiplier was ~1.3x, not 14x, and it
has been applied. The four remaining are the `IGOBJ::` spelling variants:

| address | was | slot name |
|---|---|---|
| `0057f980` | `CGObjCOS_Summoned::FUN_0057f980` | `EngageBuffSkill` |
| `0057fad0` | `CGObjCOS_Summoned::FUN_0057fad0` | `NotifyClientAPIconStatus` |
| `0057fb00` | `CGObjCOS_Summoned::FUN_0057fb00` | `IsActiveBuff` |
| `0057fb30` | `CGObjCOS_Summoned::FUN_0057fb30` | `GetRemainSkillPoint` |

## The table

| slot | offset | method |
|---|---|---|
| 1 | `0x4` | `IGObj::GetRefObjID` |
| 2 | `0x8` | `IGObj::GetJID` |
| 3 | `0xc` | `IGObj::GetGameID` |
| 4 | `0x10` | `IGObj::GetTypeID` |
| 5 | `0x14` | `IGObj::GetWorldID` |
| 6 | `0x18` | `IGObj::IsChar` |
| 7 | `0x1c` | `IGObj::IsPC` |
| 8 | `0x20` | `IGObj::IsNPC` |
| 9 | `0x24` | `IGObj::IsNPCNPC` |
| 10 | `0x28` | `IGObj::IsMonster` |
| 11 | `0x2c` | `IGObj::IsCOS` |
| 12 | `0x30` | `IGObj::IsCart` |
| 13 | `0x34` | `IGObj::IsVehicle` |
| 14 | `0x38` | `IGObj::IsPet` |
| 15 | `0x3c` | `IGObj::IsMercenary` |
| 16 | `0x40` | `IGObj::IsAttackableCOS` |
| 17 | `0x44` | `IGObj::IsStruct` |
| 18 | `0x48` | `IGObj::IsItem` |
| 19 | `0x4c` | `IGObj::IsExpendables` |
| 20 | `0x50` | `IGObj::IsContainerItem` |
| 21 | `0x54` | `IGObj::IsContainerSummonerItem` |
| 22 | `0x58` | `IGObj::IsSpecialty` |
| 23 | `0x5c` | `IGObj::IsPotion` |
| 24 | `0x60` | `IGObj::IsScroll` |
| 25 | `0x64` | `IGObj::IsBullet` |
| 26 | `0x68` | `IGObj::IsArrow` |
| 27 | `0x6c` | `IGObj::IsBolt` |
| 28 | `0x70` | `IGObj::IsHPPotion` |
| 29 | `0x74` | `IGObj::IsMPPotion` |
| 30 | `0x78` | `IGObj::IsElixir` |
| 31 | `0x7c` | `IGObj::IsGold` |
| 32 | `0x80` | `IGObj::IsTownPortal` |
| 33 | `0x84` | `IGObj::IsEquip` |
| 34 | `0x88` | `IGObj::IsWeapon` |
| 35 | `0x8c` | `IGObj::IsShield` |
| 36 | `0x90` | `IGObj::IsAccessory` |
| 37 | `0x94` | `IGObj::IsTeleportGate` |
| 38 | `0x98` | `IGObj::IsRobe` |
| 39 | `0x9c` | `IGObj::IsArmor` |
| 40 | `0xa0` | `IGObj::IsBow` |
| 41 | `0xa4` | `IGObj::IsCrossBow` |
| 42 | `0xa8` | `IGObj::IsSummonScroll` |
| 43 | `0xac` | `IGObj::IsReinforceRecipe` |
| 44 | `0xb0` | `IGObj::IsReinforceProbUP` |
| 45 | `0xb4` | `IGObj::IsFreeBattleEquip` |
| 46 | `0xb8` | `IGObj::IsQuest_n_EventItem` |
| 47 | `0xbc` | `IGObj::IsCashItem` |
| 49 | `0xc4` | `IGObj::CanTrade` |
| 50 | `0xc8` | `IGObj::CanSell` |
| 51 | `0xcc` | `IGObj::CanBorrow` |
| 52 | `0xd0` | `IGObj::CanDrop` |
| 53 | `0xd4` | `IGObj::CanPick` |
| 54 | `0xd8` | `IGObj::CanRepair` |
| 55 | `0xdc` | `IGObj::CanRevive` |
| 56 | `0xe0` | `IGObj::CanUse` |
| 57 | `0xe4` | `IGObj::CanThrow` |
| 58 | `0xe8` | `IGObj::GetCodeName` |
| 59 | `0xec` | `IGObj::GetCharName` |
| 60 | `0xf0` | `IGObj::GetNickName` |
| 61 | `0xf4` | `IGObj::GetPosInfo` |
| 62 | `0xf8` | `IGObj::GetLifeState` |
| 63 | `0xfc` | `IGObj::GetMotionState` |
| 64 | `0x100` | `IGObj::GetBodyMode` |
| 65 | `0x104` | `IGObj::GetParam` |
| 66 | `0x108` | `IGObj::GetCurHP` |
| 67 | `0x10c` | `IGObj::GetCurMP` |
| 68 | `0x110` | `IGObj::GetCurHP` |
| 69 | `0x114` | `IGObj::GetCurMP` |
| 70 | `0x118` | `IGObj::IsTargeting` |
| 71 | `0x11c` | `IGObj::GetJobState` |
| 72 | `0x120` | `IGObj::GetTeleportState` |
| 73 | `0x124` | `IGObj::GetLevel` |
| 74 | `0x128` | `IGObj::GetMaxLevel` |
| 75 | `0x12c` | `IGObj::GetMonsterClass` |
| 76 | `0x130` | `IGObj::GetPartyInfo` |
| 77 | `0x134` | `IGObj::AttachCustomTeleportCapability` |
| 78 | `0x138` | `IGObj::RegisterEventHandler` |
| 79 | `0x13c` | `IGObj::UnregisterEventHandler` |
| 80 | `0x140` | `IGObj::RaiseEvent` |
| 81 | `0x144` | `IGObj::RaiseEvent` |
| 82 | `0x148` | `IGObj::SetEventResult` |
| 83 | `0x14c` | `IGObj::RaiseEventSingle` |
| 84 | `0x150` | `IGObj::ShowMenu` |
| 85 | `0x154` | `IGObj::TerminateMenu` |
| 86 | `0x158` | `IGObj::GetMenuContext` |
| 87 | `0x15c` | `IGObj::OutputChatMsg` |
| 88 | `0x160` | `IGObj::SetCharName` |
| 89 | `0x164` | `IGObj::AddAvailableInteraction` |
| 90 | `0x168` | `IGObj::CompareGold` |
| 91 | `0x16c` | `IGObj::OffsetGold` |
| 92 | `0x170` | `IGObj::OffsetExpPoint` |
| 93 | `0x174` | `IGObj::OffsetSkillPoint` |
| 94 | `0x178` | `IGObj::GetGuildName` |
| 95 | `0x17c` | `IGObj::GetPCGuildMemberAverageLevel` |
| 96 | `0x180` | `IGObj::GetPCGuildMemberHighestLevel` |
| 97 | `0x184` | `IGObj::GetQuestData` |
| 98 | `0x188` | `IGObj::PrepareQuestData` |
| 99 | `0x18c` | `IGObj::PrepareClosedQuestData` |
| 100 | `0x190` | `IGObj::SaveClearQuestNow` |
| 101 | `0x194` | `IGObj::GetQuestStatus` |
| 102 | `0x198` | `IGObj::GetQuestStatusByName` |
| 103 | `0x19c` | `IGObj::UpdateQuestStatus` |
| 104 | `0x1a0` | `IGObj::SaveQuestNow` |
| 105 | `0x1a4` | `IGObj::GetQuestAchievementCount` |
| 106 | `0x1a8` | `IGObj::GetQuestEndDate` |
| 107 | `0x1ac` | `IGObj::GetQuestAchievementCountByName` |
| 108 | `0x1b0` | `IGObj::AddQuestAchievementCount` |
| 109 | `0x1b4` | `IGObj::SetQuestAchievementCount` |
| 110 | `0x1b8` | `IGObj::GetRecvQuestCount` |
| 111 | `0x1bc` | `IGObj::UpdateQuestContentsString` |
| 112 | `0x1c0` | `IGObj::UpdateQuestStartDataAll` |
| 113 | `0x1c4` | `IGObj::UpdateQuestTimeLimit` |
| 114 | `0x1c8` | `IGObj::UpdateQuestNpcID` |
| 115 | `0x1cc` | `IGObj::SendQuestEventMessage` |
| 116 | `0x1d0` | `IGObj::SendQuestNpcChat` |
| 117 | `0x1d4` | `IGObj::SendQuestStartTimeBar` |
| 118 | `0x1d8` | `IGObj::SendQuestCatchMobResult` |
| 119 | `0x1dc` | `IGObj::IsCatchMob` |
| 120 | `0x1e0` | `IGObj::DeleteMobForCatchQuest` |
| 121 | `0x1e4` | `IGObj::SpawnCatchCOSForCatchQuest` |
| 122 | `0x1e8` | `IGObj::SearchHaveCatchMob` |
| 123 | `0x1ec` | `IGObj::DeleteCatchCOS` |
| 124 | `0x1f0` | `IGObj::SetLifeState` |
| 125 | `0x1f4` | `IGObj::SetChangeObjActiveState` |
| 126 | `0x1f8` | `IGObj::SetInsDungeonInfo` |
| 127 | `0x1fc` | `IGObj::GetInsDungeonInfo` |
| 128 | `0x200` | `IGObj::SetEventResultInfo` |
| 129 | `0x204` | `IGObj::GetEventResultInfo` |
| 130 | `0x208` | `IGObj::Zoe` |
| 131 | `0x20c` | `IGObj::GetVolatileQuestData` |
| 132 | `0x210` | `IGObj::GetVolatileEventData` |
| 133 | `0x214` | `IGObj::RegisterSpot_Object` |
| 134 | `0x218` | `IGObj::RegisterSpot_Position` |
| 135 | `0x21c` | `IGObj::UnregisterSpot` |
| 136 | `0x220` | `IGObj::UnregisterSpotByQuest` |
| 137 | `0x224` | `IGObj::InquireSameItem` |
| 138 | `0x228` | `IGObj::FindEmptySlotNum` |
| 139 | `0x22c` | `IGObj::AddItem_EXT` |
| 140 | `0x230` | `IGObj::DelItem_EXT` |
| 141 | `0x234` | `IGObj::MutateItemAt` |
| 142 | `0x238` | `IGObj::CompareMyAndGuildMaster` |
| 143 | `0x23c` | `IGObj::QB_ForceBlockOperation` |
| 144 | `0x240` | `IGObj::QB_ReleaseBlockedJob` |
| 145 | `0x244` | `IGObj::QB_IsBlocked` |
| 146 | `0x248` | `IGObj::GetCurArmorType` |
| 147 | `0x24c` | `IGObj::GetGender` |
| 148 | `0x250` | `IGObj::AddDisplayEffect` |
| 149 | `0x254` | `IGObj::ForceDropItem` |
| 150 | `0x258` | `IGObj::GetWorldLayerData` |
| 151 | `0x25c` | `IGObj::SetWorldLayerData` |
| 152 | `0x260` | `IGObj::GetInstanceWorldUsers` |
| 153 | `0x264` | `IGObj::SaveCurPosAsLastTelPosition` |
| 154 | `0x268` | `IGObj::GetEquipedWeaponType` |
| 155 | `0x26c` | `IGObj::RefreshEventGuideData` |
| 156 | `0x270` | `IGObj::SetAvailableInteractionPerGObj` |
| 157 | `0x274` | `IGObj::BackupData` |
| 158 | `0x278` | `IGObj::AllocMsgForPeer` |
| 159 | `0x27c` | `IGObj::SendMsgToPeer` |
| 160 | `0x280` | `IGObj::SetTalkMenuTitle` |
| 161 | `0x284` | `IGObj::RegisterTalkMenuItem` |
| 162 | `0x288` | `IGObj::IsFirstTalkMenuEnable` |
| 163 | `0x28c` | `IGObj::ShowFirstTalkMenu` |
| 164 | `0x290` | `IGObj::EnableTalkMenuItem` |
| 165 | `0x294` | `IGObj::ResetQuestBlock` |
| 166 | `0x298` | `IGObj::RegisterNPCInteractionBlock` |
| 167 | `0x29c` | `IGObj::UnregisterNPCInteractionBlock` |
| 168 | `0x2a0` | `IGObj::IsInteractionAble` |
| 169 | `0x2a4` | `IGObj::ChattingByProxy` |
| 170 | `0x2a8` | `IGObj::ChattingByProxyArg` |
| 171 | `0x2ac` | `IGObj::SetCharacterState` |
| 172 | `0x2b0` | `IGObj::EnterWorld` |
| 173 | `0x2b4` | `IGObj::ExpandInventory` |
| 174 | `0x2b8` | `IGObj::ExpandInventory` |
| 175 | `0x2bc` | `IGObj::IsUsingBunusTimeOfGoldTimeItem` |
| 176 | `0x2c0` | `IGObj::IsPremiumItemPlayState` |
| 177 | `0x2c4` | `IGObj::IsQuestByCompositeItem` |
| 178 | `0x2c8` | `IGObj::UseQuestByCompositeItem` |
| 179 | `0x2cc` | `IGObj::GetRemainCountOfQuestByCompositeItem` |
| 180 | `0x2d0` | `IGObj::GetMaxCountOfQuestByCompositeItem` |
| 181 | `0x2d4` | `IGObj::GetEventHandlers` |
| 182 | `0x2d8` | `IGObj::GetWorldLayerEventHandlers` |
| 183 | `0x2dc` | `IGObj::LeaveWorldReq` |
| 184 | `0x2e0` | `IGObj::REH_OnTrapped` |
| 185 | `0x2e4` | `IGObj::GetCurSelectedObj` |
| 186 | `0x2e8` | `IGObj::IHaveTradeItem` |
| 187 | `0x2ec` | `IGObj::IHaveCart` |
| 188 | `0x2f0` | `IGObj::GetWorldLayerEventHandlers` |
| 189 | `0x2f4` | `IGObj::IHaveMercenary` |
| 190 | `0x2f8` | `IGObj::BanToDefaultWorld` |
| 191 | `0x2fc` | `IGObj::ActivateAI` |
| 192 | `0x300` | `IGObj::GetMonsterType` |
| 193 | `0x304` | `IGObj::IsPartySupportMonster` |
| 194 | `0x308` | `IGObj::ConsumeHpMp` |
| 195 | `0x30c` | `IGObj::IsChinsTombMonster` |
| 196 | `0x310` | `IGObj::EnterScriptMode` |
| 197 | `0x314` | `IGObj::UpdateHwanLevel` |
| 198 | `0x318` | `IGObj::SetBodyMode` |
| 199 | `0x31c` | `IGObj::CountEmptyInventory` |
| 200 | `0x320` | `IGOBJ::EngageBuffSkill` |
| 201 | `0x324` | `IGOBJ::PostTempleReputationSetReq` |
| 202 | `0x328` | `IGOBJ::PostTempleReputationCheckReq` |
| 203 | `0x32c` | `IGOBJ::NotifyClientAPIconStatus` |
| 204 | `0x330` | `IGOBJ::IsActiveBuff` |
| 205 | `0x334` | `IGOBJ::GetRemainSkillPoint` |
| 206 | `0x338` | `IGObj::ShowRewardWindow` |
| 207 | `0x33c` | `IGObj::IsAccomplishedCollectionBook_Theme` |
| 208 | `0x340` | `IGObj::IsAccomplishedCollectionBook_Theme` |
| 209 | `0x344` | `IGObj::IsRegisteredCollectionBook_Item` |
| 210 | `0x348` | `IGObj::IsRegisteredCollectionBook_Item` |

## `+0xa30` is the character's active skill/buff container (2026-09-17)

Not a vtable slot, but it belongs beside them: `+0xa30` on a `CGObjChar` is an
STL map holding the character's active skills and buffs, keyed by skill id.

Identified by its users rather than by its shape:

| function | what it does with it |
|---|---|
| `CMainProcess::CGame__EnterWorld` | creates it as a character enters |
| `AQ_SkillManager::vslot_007` / `_008` | the persistence pair |
| `CGSkillObject::Update` | maintains it, five call sites |
| `Stat_ApplyTaggedModifier` | reads it when applying a tagged stat modifier |
| `Formula_MitigatePhysicalDamage`, `Formula_SkillPhysDamage` | look up a damage contribution in it |
| `CGItemExpendable::vslot_307/309/329/330` | item use consults it |

**Every character has one**, which is the useful negative: its presence in a
damage formula does not tell you which participant is the attacker. See
`docs/protocol/damage_pipeline.md`, where that inference was tried and
discarded.
