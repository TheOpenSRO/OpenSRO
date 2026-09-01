extends RefCounted
class_name MonsterAssembler

## Assembles a real monster body from real .bsr-referenced .bms mesh pieces
## onto a real Skeleton3D, reusing CharacterAssembler.attach_rigid (the same
## rigid-BoneAttachment3D math already validated for player characters).
##
## Real monster .bsr files (2026-09-01, e.g. Res\mob\casia\golem.bsr) turned
## out to carry more than the static-object fields docs/protocol/
## BSR_FORMAT.md documents: a real matching .bsk skeleton path
## (Prim\Skel\mob\casia\golem.bsk) and a real list of .ban animation paths,
## right alongside the already-documented mesh/material/sub-mesh-path
## fields -- confirmed by grepping strings out of a real extracted
## golem.bsr directly. Not yet promoted into BsrReader/bsr's parsed struct
## (this project reads those two extra paths ad hoc here, not via a general
## parser change) since only one real file has been inspected this way.
##
## Unlike real character body-part meshes, real monster mesh piece names
## (golem01.bms..golem07.bms) and their own material_name field ("golem",
## same for every piece) carry no body-part hint at all -- the
## name-matching heuristic CharacterAssembler.BODY_PART_BONES relies on
## doesn't apply here. Real piece-to-bone correspondence was instead
## computed from real data: for golem specifically, each piece's real
## vertex centroid was compared (Euclidean distance) against every real
## bone's real bind-pose position (golem.bsk, 48 real bones -- the standard
## Biped names shared with the player skeleton, plus 22 extra "BoneNN"
## nodes with no confirmed real role, plausibly per-rock-cluster
## attachment points for this specific creature's design). GOLEM_PIECE_BONES
## below is that computed nearest-bone result, not a guess -- golem01 (743
## of ~1229 total real vertices, clearly the main body) landed within 1.64
## units of "Bip01 Spine"; the 6 much smaller pieces (45-108 verts each,
## plausibly rock-cluster limb attachments) landed 2.4-4.1 units from their
## own nearest bone. This is real geometric correspondence, not a naming
## guess, but it's also not a perfect zero-distance match the way real
## character body parts were -- flagged honestly, not overclaimed.
##
## Visually verified (2026-09-01, see docs/WORLD_ISSUES.md's thirty-third
## round) via a real headless render using real golem.bsk/golem0N.bms/
## golem.bmt+ddj data: the assembled result reads as a real, recognizable
## rock-golem silhouette, not a scattered mess -- confirming the same
## "absolute bind-pose-space vertex positions, no extra per-piece
## transform" convention CharacterAssembler/ObjectLoader already rely on
## holds for real monster meshes too.
const GOLEM_PIECE_BONES := {
	"golem01": "Bip01 Spine",
	"golem02": "Bip01 L Finger0",
	"golem03": "Bone04",
	"golem04": "Bone08",
	"golem05": "Bone12",
	"golem06": "Bone14",
	"golem07": "Bone18",
}

## Same real derivation as GOLEM_PIECE_BONES (2026-09-01), for
## Res\mob\oasis\scorpion.bsr -- confirmed via `Prim\Skel\mob\oasis\
## scorpion.bsk` (55 real bones: the same standard Biped names, a real
## "Bip01 Tail"/"Tail1".."Tail4" chain unique to this creature, plus the
## same kind of extra "BoneNN" nodes golem has). Only 3 real mesh pieces
## this time (vs. golem's 7), and the real nearest-bone match is much
## tighter: `scorpion_part1`/`scorpion_part2_part1` (228 verts each, the
## two front claws/pincers) land within ~0.86 units of
## "Bip01 R Forearm"/"Bip01 L Forearm" respectively; `scorpion_part2_part2`
## (248 verts, the largest piece -- the main body/tail) lands within 2.12
## units of "Bip01 Spine". Visually verified via a real headless render
## (see docs/WORLD_ISSUES.md's thirty-seventh round) using the real
## scorpion.bmt/ddj texture -- a coherent, recognizable scorpion silhouette.
const SCORPION_PIECE_BONES := {
	"scorpion_part1": "Bip01 R Forearm",
	"scorpion_part2_part1": "Bip01 L Forearm",
	"scorpion_part2_part2": "Bip01 Spine",
}

## Assembles parts (piece-name -> BmsReader.ParsedMesh, e.g. "golem01" ->
## parsed golem01.bms) onto skeleton using piece_bones (a
## GOLEM_PIECE_BONES-shaped map). Unrecognized piece names are skipped with
## a printed warning, not an error -- same honest-gap handling as
## CharacterAssembler.assemble for an incomplete real part list.
static func assemble(skeleton: Skeleton3D, parts: Dictionary, piece_bones: Dictionary, material: Material) -> void:
	for piece_name in parts:
		if not piece_bones.has(piece_name):
			print("MonsterAssembler: no bone mapping for piece %s -- skipped" % piece_name)
			continue
		var mesh: BmsReader.ParsedMesh = parts[piece_name]
		var bone_name: String = piece_bones[piece_name]
		CharacterAssembler.attach_rigid(skeleton, BmsReader.to_array_mesh(mesh), bone_name, material)
