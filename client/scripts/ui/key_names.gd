extends RefCounted
class_name KeyNames

## The Option window's Key Map tab (round 833): which keys a row takes and
## how a key is written in its box, on the Windows virtual-key codes the
## original works in. KeyMap stores Godot keycodes; vk_of translates.
##
## READ (sro_client.exe):
##   - The key handler 0x5fb460 refuses a VK by the byte table at 0x5fb544
##     (`lea eax,[esi-0xc]; cmp eax,0xd9`): 0x0C, 0x13 Pause, 0x15, 0x17-0x19,
##     0x1B Esc, 0x25-0x28 the arrows, 0x2C PrintScreen, 0x30-0x39 the
##     digits, 0x5F-0x7B (the numpad, its operators, F1-F12), 0x90-0x91
##     NumLock / ScrollLock and 0xE5. Every other VK is taken.
##   - The box's text is the switch 0x6ed9e0 (UTF-16 strings, see NAMES); any
##     other VK is the one character (VK & 0xff), so a letter is itself.
## INFERRED: Alt reaches a window as WM_SYSKEYDOWN, which the option
## window's message map (0xd69480: WM_CHAR, WM_KEYDOWN) does not take, so the
## original never binds Alt although its table would; refused here too.

const VK_ALT := 0x12

## 0x6ed9e0's names (READ). VK 0 (an unbound row) is one space.
const NAMES := {
	0x00: " ", 0x08: "←", 0x09: "Tab", 0x0D: "Enter", 0x10: "Shift", 0x11: "Ctrl",
	0x12: "Alt", 0x14: "C/L", 0x20: "Space", 0x21: "PgUp", 0x22: "PgDn", 0x23: "End",
	0x24: "Home", 0x25: "←", 0x26: "↑", 0x27: "→", 0x28: "↓", 0x2D: "Ins", 0x2E: "Del",
	0x70: "F1", 0x71: "F2", 0x72: "F3", 0x73: "F4", 0x74: "F5", 0x75: "F6", 0x76: "F7",
	0x77: "F8", 0x78: "F9", 0x79: "F10", 0x7A: "F11", 0x7B: "F12",
	0xBA: ";", 0xBB: "=", 0xBC: ",", 0xBD: "-", 0xBE: ".", 0xBF: "/", 0xC0: "`",
	0xDB: "[", 0xDC: "\\", 0xDD: "]", 0xDE: "'",
}

## Godot keycodes that are not their VK (letters and digits are).
const _VK := {
	KEY_BACKSPACE: 0x08, KEY_TAB: 0x09, KEY_ENTER: 0x0D, KEY_KP_ENTER: 0x0D,
	KEY_SHIFT: 0x10, KEY_CTRL: 0x11, KEY_ALT: 0x12, KEY_PAUSE: 0x13, KEY_CAPSLOCK: 0x14,
	KEY_ESCAPE: 0x1B, KEY_SPACE: 0x20, KEY_PAGEUP: 0x21, KEY_PAGEDOWN: 0x22, KEY_END: 0x23,
	KEY_HOME: 0x24, KEY_LEFT: 0x25, KEY_UP: 0x26, KEY_RIGHT: 0x27, KEY_DOWN: 0x28,
	KEY_PRINT: 0x2C, KEY_INSERT: 0x2D, KEY_DELETE: 0x2E, KEY_META: 0x5B, KEY_MENU: 0x5D,
	KEY_KP_0: 0x60, KEY_KP_1: 0x61, KEY_KP_2: 0x62, KEY_KP_3: 0x63, KEY_KP_4: 0x64,
	KEY_KP_5: 0x65, KEY_KP_6: 0x66, KEY_KP_7: 0x67, KEY_KP_8: 0x68, KEY_KP_9: 0x69,
	KEY_KP_MULTIPLY: 0x6A, KEY_KP_ADD: 0x6B, KEY_KP_SUBTRACT: 0x6D, KEY_KP_PERIOD: 0x6E,
	KEY_KP_DIVIDE: 0x6F, KEY_NUMLOCK: 0x90, KEY_SCROLLLOCK: 0x91,
	KEY_SEMICOLON: 0xBA, KEY_EQUAL: 0xBB, KEY_COMMA: 0xBC, KEY_MINUS: 0xBD, KEY_PERIOD: 0xBE,
	KEY_SLASH: 0xBF, KEY_QUOTELEFT: 0xC0, KEY_BRACKETLEFT: 0xDB, KEY_BACKSLASH: 0xDC,
	KEY_BRACKETRIGHT: 0xDD, KEY_APOSTROPHE: 0xDE,
}

## The VK of a Godot keycode, or -1 for a key with none here (OURS: such a
## key is refused).
static func vk_of(keycode: int) -> int:
	if keycode == KEY_NONE:
		return 0
	if (keycode >= KEY_A and keycode <= KEY_Z) or (keycode >= KEY_0 and keycode <= KEY_9):
		return keycode
	if keycode >= KEY_F1 and keycode <= KEY_F24:
		return 0x70 + keycode - KEY_F1
	return int(_VK.get(keycode, -1))

## Whether a row takes this VK (0x5fb544, READ; Alt INFERRED, see above).
static func accepts_vk(vk: int) -> bool:
	if vk < 0 or vk == VK_ALT:
		return false
	if vk == 0x0C or vk == 0x13 or vk == 0x15 or vk == 0x1B or vk == 0x2C or vk == 0xE5:
		return false
	if (vk >= 0x17 and vk <= 0x19) or (vk >= 0x25 and vk <= 0x28) or (vk >= 0x30 and vk <= 0x39):
		return false
	if (vk >= 0x5F and vk <= 0x7B) or (vk >= 0x90 and vk <= 0x91):
		return false
	return true

static func accepts(keycode: int) -> bool:
	return keycode != KEY_NONE and accepts_vk(vk_of(keycode))

## The box's text for a VK (0x6ed9e0, READ).
static func name_of_vk(vk: int) -> String:
	if NAMES.has(vk):
		return String(NAMES[vk])
	return String.chr(vk & 0xff)

## The box's text for a Godot keycode (KEY_NONE: the unbound row's space).
static func name_of(keycode: int) -> String:
	var vk := vk_of(keycode)
	return name_of_vk(vk) if vk >= 0 else OS.get_keycode_string(keycode)
