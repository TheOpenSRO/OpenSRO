extends RefCounted
class_name CharSelectHandoff

## What the character select screen hands the customize screen, and what
## comes back (round 684; the contract in docs/protocol/charselect.md, "Lane
## A <-> lane B handoff"). Static, so it survives a scene change -- the way
## retail keeps the race in a global the create process reads.
##
## READ (sro_client.exe):
## - The race select stores its pick in DAT_00ec2d68 (copied from the hovered
##   idol's index at 0x85ca47, CPSCharacterSelect::FUN_0085ca10). That index
##   is 0 for the Europe idol and 1 for the China idol: index 0 flies the
##   camera to (168.5, -34.9, 639.1) (the floats at 0xdd7cfc) and switches to
##   the process at DAT_00eed8d4, index 1 to (165.8, -35.1, 636.7) (0xdd7d08)
##   and DAT_00eed8b4 (vslot_012 case 9). `race` below is NOT that index: it
##   is translated to CharCatalog's race (Country: 0 China, 1 Europe), which
##   every lane already uses (OURS, so no second numbering leaks out).
## - The create screens leave by writing the previous-process id the select
##   screen reads at OnCreate (`*(gfx+0x28)+0xe8`): 0 after a character was
##   created, 0xa after Cancel (charselect.md section 1). The select screen
##   runs its list intro for both.

const CREATE_SCENE := "res://scenes/CharacterCreate.tscn"
const SELECT_SCENE := "res://scenes/CharacterSelect.tscn"

## READ: the previous-process ids above.
const FROM_CREATE_OK := 0
const FROM_CREATE_CANCEL := 10
## OURS: select opened from login (or anything else).
const FROM_OTHER := -1

## CharCatalog.RACE_CHINA / RACE_EUROPE, or -1 when no race was chosen (the
## create screen opened directly: it picks its own default).
static var race: int = -1
## The title's random hour (TitleIntro.pick_day_phase), carried through the
## front-end screens, none of which picks its own (READ: none calls
## SWorld::vslot_020, charselect.md section 1). -1 when unknown.
static var day_phase: float = -1.0

## The hour the front-end screens draw at (round 688): the title's, and when
## no title set one (a screen opened directly) one picked the title's way
## ONCE and kept, so select, customize and select again share it. READ:
## SWorld (one global, built once by the static initialiser 0xd768f0 ->
## Map::FUN_00a2f370, phase 0.5) keeps its day phase at +0x26a3, set through
## vslot_020. On the front-end path its only caller is CPSTitle's OnCreate
## (rand() & 3, unconditionally, 0x86b278); in the game CPSMission::vslot_012
## sets it every frame from the game clock, and two console handlers
## (0x53a4d0, 0x53a520) set it too (round 688's review). The world clock that
## would advance it by itself (0xa2d130, phase += dt x 0.0005) runs only while
## +0x2f18 is set, which only the constructor writes, to 0. So the hour the
## title picked holds through select and customize until the title is shown
## again. Until round 688 a screen with
## no title's hour picked a NEW one on every visit.
static func front_end_phase() -> float:
	if day_phase < 0.0:
		day_phase = TitleIntro.pick_day_phase()
	return day_phase
## The front-end theme Login resolved (FrontEndTheme), for the same branding
## on the later screens; null when none was resolved.
static var theme: FrontEndTheme = null
## How the select screen was reached (FROM_*).
static var came_from: int = FROM_OTHER

## Retail's race-select index (0 Europe idol, 1 China idol; READ above) as
## CharCatalog's race, -1 for anything else.
static func race_from_idol_index(index: int) -> int:
	match index:
		0:
			return CharCatalog.RACE_EUROPE
		1:
			return CharCatalog.RACE_CHINA
	return -1

## Select -> customize: remembers the race and changes scene.
static func go_create(tree: SceneTree, chosen_race: int) -> void:
	race = chosen_race
	tree.change_scene_to_file(CREATE_SCENE)

## Customize -> select: `created` true after the server accepted the new
## character, false on Cancel.
static func back_to_select(tree: SceneTree, created: bool) -> void:
	came_from = FROM_CREATE_OK if created else FROM_CREATE_CANCEL
	tree.change_scene_to_file(SELECT_SCENE)
