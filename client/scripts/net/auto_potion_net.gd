extends RefCounted
class_name AutoPotionNet

## The Auto potion window's settings on the wire (round 786; server
## session/autopotion.go, docs/protocol/auto_potion.md).
##
## READ: retail's Confirm sends 0x7158 {u8 2, u16 HP, u16 MP, u16 abnormal,
## u8 delay} (CAutoPotion::Send 0x82d2e0; the server stores it unchecked,
## FUN_00407ee0) and reads the same seven bytes back from its character data
## (0x8a7bd0). OpenSRO's character data is not retail's, so the client asks
## for them once it is in the world (OP_LOAD, OURS) and they come back on
## OP_CONFIG (OURS), the same seven bytes.
const OP_SAVE := 0x7158   # client -> server, retail's number and body
const OP_CONFIG := 0x0116 # server -> client: the seven bytes (OURS)
const OP_LOAD := 0x0117   # client -> server, empty: ask for them (OURS)

## 0x7158's type byte for these settings (the server's FUN_00518c20 type 2).
const TYPE_AUTO_POTION := 2

static func encode_save(settings: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([TYPE_AUTO_POTION])
	out.append_array(settings)
	return out
