extends PartyMatchConfirm
class_name JobConfirmBox

## Round 799: the job guild's questions -- join (UIIT_STT_JOBGUILD_JOIN_WINDOW),
## leave (UIIT_STT_JOBGUILD_WITHD_WINDOW), the alias's create and change
## (UIIT_STT_ALIAS_CREATE_WINDOW / _MODIFY_WINDOW). READ: the talk lines
## 0x1e / 0x1f open a confirm box (CIF_NPCTalk::FUN_007020c0 case 0x1e
## 0x70307e: FUN_006f8cb0 kind 4, with the property "tri_job_type"; case 0x1f
## 0x7030bc: kind 5) and the box's OK sends the request (0x6f7acc..0x6f7b0b);
## the alias window's OK opens UIIT_STT_CONFIRM_BOX with the alias text
## (CIFJobAlias 0x74b110). The texts are sml2 PML (centred lines, a coloured
## cost), drawn by PmlText (round 848; a Godot RichTextLabel fed BBCode
## before), white as the box's message line. OURS: the box is the party dialogs' question
## box (PartyMatchConfirm, ifmessagebox's MsgBoxSimple, Yes / No); kinds 4
## and 5's own geometry and button words were not read.

func build_sml(builder: UiBuilder, sml: String) -> bool:
	if not build(builder, ""):
		return false
	name = "JobConfirmBox"
	var plain := get_node_or_null("Message") as Label
	var rich := PmlText.new()
	rich.name = "Sml"
	rich.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if plain != null:
		rich.position = plain.position
		rich.size = plain.size
		plain.visible = false
	add_child(rich)
	rich.setup(builder.font_at(0) if builder != null else null, UiBuilder.FONT_SIZES[0], Color.WHITE)
	rich.set_markup(sml)
	return true
