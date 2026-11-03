class_name ScrollHold
extends RefCounted

## Round 860: the return scroll's hold. READ (SR_GameServer.exe, the PC's
## message filter GObjPC::FUN_004296a0, built by RegisterValueListFilters
## 0x427d90; server/internal/session/scrollhold.go has every address): while
## the character's scroll state -- 0x30BF kind 0xb, GetTeleportState -- is 1,
## only chat (0x7025), item use (0x704C), the cast's cancel (0x705B), 0x7005
## and 0x34BF pass; the move 0x7021, the arrow keys' 0x7023 / 0x7024 and the
## action 0x7074 (attacks, skills) are refused. Group 11 has a record for
## value 1 only: the thief-den scrolls' state 2 is not held.

## The scroll state's value the filter holds.
const HOLD_VALUE := 1

## Whether the scroll state `state` holds its character.
static func holds(state: int) -> bool:
	return state == HOLD_VALUE
