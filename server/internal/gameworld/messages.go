package gameworld

import (
	"encoding/binary"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// EncodeCloseWarning is the instance close warning, 0x300C {u16 0x0C1A, u8
// minutes} (READ c:0x8764da: UIIT_MSG_EGYPT_DUNGEON_DESTROY_ALARM's %d; the
// shard manager's GAMEWORLD_DISAPPEARANCE_TIME thresholds, game_worlds.md 4).
func EncodeCloseWarning(left time.Duration) []byte {
	b := binary.LittleEndian.AppendUint16(nil, proto.NoticeWordInstanceCloses)
	return append(b, uint8(left/time.Minute))
}

// EncodeTriggerNotice is a trigger's message, 0x300C {u16 0x0C1C, u8 kind,
// str key} (READ s:0x5f9450, c:0x87657d..0x876670: kind 1 the notice banner,
// 2 a system line; the key is a text-table key; the string is u16 length +
// ANSI bytes).
func EncodeTriggerNotice(kind uint8, key string) []byte {
	b := binary.LittleEndian.AppendUint16(nil, proto.NoticeWordTriggerMessage)
	b = append(b, kind)
	b = binary.LittleEndian.AppendUint16(b, uint16(len(key)))
	return append(b, key...)
}

// EncodeGroupCoolTime is the re-entry limit's timed-job push, 0x320C {u8
// 0x0C, u32 group id, u32 remaining seconds} (READ c:0x88dad0 -> c:0x778f90:
// a buff-bar icon of kind 0xE; game_worlds.md 5).
func EncodeGroupCoolTime(group uint32, remaining time.Duration) []byte {
	b := []byte{proto.TimedJobKindWorldGroup}
	b = binary.LittleEndian.AppendUint32(b, group)
	secs := remaining / time.Second
	if secs < 0 {
		secs = 0
	}
	return binary.LittleEndian.AppendUint32(b, uint32(secs))
}
