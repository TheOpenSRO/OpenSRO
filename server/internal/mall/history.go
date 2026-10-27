package mall

import (
	"encoding/binary"
	"time"
)

// The silk history (item_mall_wire.md §5):
//
//	C->S 0x711a {u8 kind, u8 period}
//	S->C 0xB11A {u8 kind, u8 period, u8 result} and, when result is 0,
//	            {u16 n, n x {u32 silkOffset, u32 date}}
//
// READ: the request's senders (c:0x7d40c0, 0x7ecb90 send {1, combo+1} for
// combo 0..3; the close sends {1|2, 0xff}); period 0xff cancels the pending
// inquiry and no query runs (sm:0x413fc2 -> sm:0x41d160): no reply. The
// client (c:0x8990c0) puts kind 1 into the Buying list and any other kind
// into the Obtained list, stops on a non-zero result and shows "No history is
// available." for n = 0.
//
// The date word is READ off the row drawer c:0x7ea310, which prints it with
// "%4d/%02d/%02d %02d:%02d" (UTF-16 at c:0xdcbf78) from these fields:
//
//	bits 0..5   year - 2000      (& 0x3f, + 0x7d0)
//	bits 6..9   month            (>> 6 & 0xf)
//	bits 10..14 day              (>> 0xa & 0x1f)
//	bits 15..19 hour             (>> 0xf & 0x1f)
//	bits 20..25 minute           (>> 0x14 & 0x3f)
//
// Bits 26..31 are not read by the drawer; they are written 0 here. Which
// clock retail's billing side wrote is OPEN; OpenSRO writes the server's
// local time (OURS).
const (
	OpHistory         uint16 = 0x711a
	OpHistoryResult   uint16 = 0xB11A
	HistoryCancel     byte   = 0xff
	HistoryBuying     byte   = 1 // the Buying list
	HistoryObtained   byte   = 2 // the Obtained list (disabled in retail's window)
	historyOK         byte   = 0
	historyFailed     byte   = 1 // OURS: any non-zero result; the client does nothing with it
	MaxHistoryRows           = 500
	historyYearOrigin        = 2000
)

// PackDate is the 0xB11A date word for t (local time).
func PackDate(t time.Time) uint32 {
	t = t.Local()
	y := t.Year() - historyYearOrigin
	if y < 0 {
		y = 0
	}
	return uint32(y&0x3f) | uint32(t.Month())<<6 | uint32(t.Day())<<10 | uint32(t.Hour())<<15 | uint32(t.Minute())<<20
}

// UnpackDate is the drawer's reading of a date word, for the tests and the bot.
func UnpackDate(d uint32) (year, month, day, hour, minute int) {
	return int(d&0x3f) + historyYearOrigin, int(d >> 6 & 0xf), int(d >> 10 & 0x1f), int(d >> 15 & 0x1f), int(d >> 20 & 0x3f)
}

// PeriodStart is the oldest time a period covers. INFERRED from
// _GetSilkHistory (MEASURED text: 1 a day, 2 a week, 3 a month, 4 three
// months; the GameServer relays the byte unchanged). ok false for any other
// period, which makes that procedure's query fail (an empty condition).
func PeriodStart(period byte, now time.Time) (time.Time, bool) {
	switch period {
	case 1:
		return now.Add(-24 * time.Hour), true
	case 2:
		return now.Add(-7 * 24 * time.Hour), true
	case 3:
		return now.AddDate(0, -1, 0), true
	case 4:
		return now.AddDate(0, -3, 0), true
	}
	return time.Time{}, false
}

// HistoryRow is one line: the silk a purchase took and when.
type HistoryRow struct {
	Offset int64
	At     time.Time
}

// DecodeHistory reads 0x711a.
func DecodeHistory(b []byte) (kind, period byte, ok bool) {
	if len(b) < 2 {
		return 0, 0, false
	}
	return b[0], b[1], true
}

// EncodeHistory is 0xB11A with result 0 and the rows (at most
// MaxHistoryRows, OURS).
func EncodeHistory(kind, period byte, rows []HistoryRow) []byte {
	if len(rows) > MaxHistoryRows {
		rows = rows[:MaxHistoryRows]
	}
	out := []byte{kind, period, historyOK}
	out = binary.LittleEndian.AppendUint16(out, uint16(len(rows)))
	for _, r := range rows {
		out = binary.LittleEndian.AppendUint32(out, clampU32(r.Offset))
		out = binary.LittleEndian.AppendUint32(out, PackDate(r.At))
	}
	return out
}

// EncodeHistoryFailed is 0xB11A with a non-zero result (OURS: for a kind or
// period retail's query cannot answer).
func EncodeHistoryFailed(kind, period byte) []byte {
	return []byte{kind, period, historyFailed}
}
