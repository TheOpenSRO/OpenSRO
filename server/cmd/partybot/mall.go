package main

// Round 837 (QA): the bot's item mall steps on the wire (session/mall.go,
// internal/mall). -mall-buy names a good as the client would send it; GM
// lines (-gm-lines "/silk 1000") give the silk first. Every reply is logged:
// 0x3153, 0x3154, 0xB034 (type 0x18), 0xB11A and the chest's 0x00D1, 0x00D3,
// 0x00D5, 0x00D6.

import (
	"encoding/binary"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

var botMall struct {
	buy     string // -mall-buy "<group>,<shop>,<tab>,<slot>,<packageCode>,<qty>[,<points>]"
	repeat  int    // -mall-buy-times
	chest   string // -mall-chest: "list", "all" (take all) or an entry id
	history string // -mall-history "<kind>,<period>"
	open    int    // -mall-open: send 0x7121 with this group first (0: not)
	delay   time.Duration
	// use is -use-slots (round 838): bag slots to use (0x008a), in order,
	// after the other mall steps.
	use string
}

func mallLog(b *bot, format string, args ...any) {
	fmt.Printf("%s [%s] MALL %s\n", time.Now().Format("15:04:05.000"), b.name, fmt.Sprintf(format, args...))
}

// parseMallBuy reads -mall-buy.
func parseMallBuy(s string) (mall.BuyRequest, error) {
	f := strings.Split(s, ",")
	if len(f) < 6 || len(f) > 7 {
		return mall.BuyRequest{}, fmt.Errorf("-mall-buy wants group,shop,tab,slot,packageCode,qty[,points]")
	}
	n := make([]uint64, 0, 7)
	for i, v := range f {
		if i == 4 {
			continue
		}
		x, err := strconv.ParseUint(strings.TrimSpace(v), 10, 64)
		if err != nil {
			return mall.BuyRequest{}, fmt.Errorf("-mall-buy field %d: %v", i+1, err)
		}
		n = append(n, x)
	}
	r := mall.BuyRequest{Group: uint16(n[0]), Shop: uint8(n[1]), Tab: uint8(n[2]), Slot: uint8(n[3]),
		Code: strings.TrimSpace(f[4]), Quantity: uint16(n[4])}
	if len(n) > 5 {
		r.Points = n[5]
	}
	return r, nil
}

// mallSteps runs the mall steps once in the world, -social-delay apart.
func (b *bot) mallSteps() {
	m := &botMall
	if m.buy == "" && m.chest == "" && m.history == "" && m.open == 0 && m.use == "" {
		return
	}
	go func() {
		time.Sleep(m.delay)
		if m.open != 0 {
			mallLog(b, "-> 0x7121 open, group %d", m.open)
			_ = b.send(mall.OpOpen, binary.LittleEndian.AppendUint16(nil, uint16(m.open)))
			time.Sleep(m.delay)
		}
		if m.buy != "" {
			r, err := parseMallBuy(m.buy)
			if err != nil {
				mallLog(b, "%v", err)
				return
			}
			for i := 0; i < max(m.repeat, 1); i++ {
				mallLog(b, "-> 0x7034 type 0x18 buy %+v", r)
				_ = b.send(session.OpItemMove, mall.EncodeBuy(r))
				time.Sleep(m.delay)
			}
		}
		if m.chest != "" {
			mallLog(b, "-> 0x00D0 chest list")
			_ = b.send(mall.OpChestList, nil)
			time.Sleep(m.delay)
			if m.chest != "list" {
				id := uint64(mall.TakeAll)
				if m.chest != "all" {
					id, _ = strconv.ParseUint(m.chest, 10, 32)
				}
				mallLog(b, "-> 0x00D2 take %d (0 = all)", id)
				_ = b.send(mall.OpChestTake, binary.LittleEndian.AppendUint32(nil, uint32(id)))
				time.Sleep(m.delay)
				mallLog(b, "-> 0x00D4 take log")
				_ = b.send(mall.OpChestLog, nil)
				time.Sleep(m.delay)
				_ = b.send(session.OpInventoryList, (&session.CharacterNameRequest{Name: b.name}).Encode())
			}
		}
		if m.history != "" {
			var kind, period int
			if _, err := fmt.Sscanf(m.history, "%d,%d", &kind, &period); err == nil {
				mallLog(b, "-> 0x711a {%d, %d}", kind, period)
				_ = b.send(mall.OpHistory, []byte{byte(kind), byte(period)})
			}
		}
		// Round 838: the service scrolls, used from the bag.
		for _, f := range strings.Split(m.use, ",") {
			slot, err := strconv.Atoi(strings.TrimSpace(f))
			if err != nil {
				continue
			}
			time.Sleep(m.delay)
			mallLog(b, "-> 0x008a use bag slot %d", slot)
			_ = b.send(session.OpUseItem, (&session.UseItemRequest{CharacterName: b.name, InventorySlot: int32(slot)}).Encode())
		}
	}()
}

// noteMall logs the mall's messages.
func (b *bot) noteMall(op uint16, data []byte) {
	u32 := func(i int) uint32 { return binary.LittleEndian.Uint32(data[i:]) }
	switch op {
	case mall.OpSilk:
		if len(data) >= 12 {
			mallLog(b, "0x3153 silk own %d gift %d point %d", u32(0), u32(4), u32(8))
		}
	case mall.OpSilkChange:
		if len(data) >= 6 {
			mallLog(b, "0x3154 reason %d cash type %d offset %d", data[0], data[1], u32(2))
		}
	case session.OpItemMoveResult:
		if len(data) >= 2 && data[0] == 1 && data[1] == mall.BuyType {
			mallLog(b, "0xB034 buy ok % x (n = %d; 0 = to the chest)", data, data[7])
		} else if len(data) >= 3 && data[0] == 2 {
			mallLog(b, "0xB034 refused %#04x", binary.LittleEndian.Uint16(data[1:]))
		}
	case mall.OpHistoryResult:
		mallLog(b, "0xB11A % x", data)
		if len(data) >= 5 && data[2] == 0 {
			n := int(binary.LittleEndian.Uint16(data[3:]))
			for i := 0; i < n && 5+8*i+8 <= len(data); i++ {
				y, mo, d, h, mi := mall.UnpackDate(u32(5 + 8*i + 4))
				mallLog(b, "  row %d: %d silk at %04d/%02d/%02d %02d:%02d", i+1, u32(5+8*i), y, mo, d, h, mi)
			}
		}
	case mall.OpOpenResult, mall.OpChestListResult, mall.OpChestTakeResult, mall.OpChestLogResult, mall.OpChestReceived:
		mallLog(b, "%#04x % x", op, data)
	// Round 838: the service scrolls' answers.
	case session.OpUseItemResult:
		if r, err := session.DecodeUseItemResult(data); err == nil {
			mallLog(b, "0x008b use: error %q, %d left, item %d", r.Error, r.Remaining, r.ItemID)
		}
	case session.OpServiceLine:
		if len(data) >= 2 {
			mallLog(b, "0x0138 %q", string(data[2:]))
		}
	case session.OpPlateColours:
		if len(data) >= 12 {
			mallLog(b, "0x013B uid %d name %08x title %08x", u32(0), u32(4), u32(8))
		}
	}
}
