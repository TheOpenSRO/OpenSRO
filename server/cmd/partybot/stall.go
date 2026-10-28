package main

// Round 839 (QA, lane S): the bot's stall steps on the retail wire
// (session/stall.go, docs/protocol/stall.md) -- one bot owns a stall and the
// client buys, or the client owns one and a bot visits and buys. Every step
// waits -stall-delay first, so a run sees the messages in the order a
// person's clicks give them.
//
//	-stall-open "title"         open a stall once in the world (0x70B1), the
//	                            greeting (-stall-greeting, 0x70BA type 6),
//	                            each -stall-items entry (type 2), then open
//	                            for business (type 5) unless -stall-modify
//	-stall-items "i71:500,i4:30" item ids (or bag indexes) and prices
//	-stall-close-after D        close it (0x70B2) after D
//	-stall-visit NAME           enter NAME's stall (0x70B3) once it is seen
//	                            stalling, then buy -stall-buy's slots (0x70B4)
//	-stall-leave-after D        leave it (0x70B5) after D
//	-stall-chat "text"          a stall chat line (type 9) once inside / open

import (
	"encoding/binary"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// botRace is -bot-race.
var botRace string

var botStall struct {
	open       string
	items      string
	greeting   string
	modify     bool
	group      uint
	closeAfter time.Duration
	visit      string
	buy        string
	leaveAfter time.Duration
	buyAfter   time.Duration
	chat       string
	delay      time.Duration

	mu      sync.Mutex
	entered bool
	qty     map[int]int
}

func stallLog(b *bot, format string, args ...any) {
	socialLog(b, "STALL "+format, args...)
}

func stallStr(s string) []byte {
	return append(binary.LittleEndian.AppendUint16(nil, uint16(len(s))), s...)
}

// stallSteps opens the bot's own stall (-stall-open).
func (b *bot) stallSteps() {
	s := &botStall
	if s.open == "" {
		return
	}
	go func() {
		_ = b.send(session.OpInventoryList, (&session.CharacterNameRequest{Name: b.name}).Encode())
		time.Sleep(s.delay)
		stallLog(b, "opens %q (0x70B1)", s.open)
		_ = b.send(session.OpStallOpen, stallStr(s.open))
		if s.greeting != "" {
			time.Sleep(s.delay)
			stallLog(b, "greeting %q (0x70BA 6)", s.greeting)
			_ = b.send(session.OpStallUpdate, append([]byte{session.StallUpdateWelcome}, stallStr(s.greeting)...))
		}
		slot := 0
		for _, f := range strings.Split(s.items, ",") {
			f = strings.TrimSpace(f)
			parts := strings.SplitN(f, ":", 2)
			if f == "" || len(parts) != 2 {
				continue
			}
			price, err := strconv.ParseUint(parts[1], 10, 64)
			if err != nil {
				continue
			}
			idx := -1
			if strings.HasPrefix(parts[0], "i") {
				id, err := strconv.ParseInt(parts[0][1:], 10, 64)
				if err != nil {
					continue
				}
				bagSlots.Lock()
				if v, ok := bagSlots.byItem[id]; ok {
					idx = v
				}
				bagSlots.Unlock()
			} else if v, err := strconv.Atoi(parts[0]); err == nil {
				idx = v
			}
			if idx < 0 {
				stallLog(b, "has no %s in its bag", parts[0])
				continue
			}
			s.mu.Lock()
			qty := s.qty[idx]
			s.mu.Unlock()
			if qty <= 0 {
				qty = 1
			}
			time.Sleep(s.delay)
			body := []byte{session.StallUpdateAdd, byte(slot), byte(idx + session.ItemWireBagOffset)}
			body = binary.LittleEndian.AppendUint16(body, uint16(qty))
			body = binary.LittleEndian.AppendUint64(body, price)
			body = binary.LittleEndian.AppendUint32(body, uint32(s.group))
			body = binary.LittleEndian.AppendUint16(body, 0)
			stallLog(b, "lists bag slot %d x%d at %d in slot %d (0x70BA 2)", idx, qty, price, slot)
			_ = b.send(session.OpStallUpdate, body)
			slot++
		}
		if !s.modify {
			time.Sleep(s.delay)
			stallLog(b, "opens for business (0x70BA 5)")
			_ = b.send(session.OpStallUpdate, []byte{session.StallUpdateOpen, 1, 0, 0})
		}
		if s.chat != "" {
			time.Sleep(s.delay)
			b.stallChat()
		}
		if s.closeAfter > 0 {
			time.Sleep(s.closeAfter)
			stallLog(b, "closes (0x70B2)")
			_ = b.send(session.OpStallClose, nil)
		}
	}()
}

func (b *bot) stallChat() {
	stallLog(b, "says %q (chat type 9)", botStall.chat)
	_ = b.send(session.OpChatSend, (&session.ChatSendRequest{Type: session.ChatStall, Index: 1, Message: botStall.chat}).Encode())
}

// stallSeen enters -stall-visit's stall once it is seen stalling (its spawn
// record or 0x30B8).
func (b *bot) stallSeen(name string, uid uint32) {
	s := &botStall
	if s.visit == "" || name != s.visit {
		return
	}
	s.mu.Lock()
	if s.entered {
		s.mu.Unlock()
		return
	}
	s.entered = true
	s.mu.Unlock()
	go func() {
		time.Sleep(s.delay)
		stallLog(b, "enters %s's stall (0x70B3 %d)", name, uid)
		_ = b.send(session.OpStallEnter, binary.LittleEndian.AppendUint32(nil, uid))
		time.Sleep(s.buyAfter)
		for _, f := range strings.Split(s.buy, ",") {
			if n, err := strconv.Atoi(strings.TrimSpace(f)); err == nil {
				time.Sleep(s.delay)
				stallLog(b, "buys slot %d (0x70B4)", n)
				_ = b.send(session.OpStallBuy, []byte{byte(n)})
			}
		}
		if s.chat != "" {
			time.Sleep(s.delay)
			b.stallChat()
		}
		if s.leaveAfter > 0 {
			time.Sleep(s.leaveAfter)
			stallLog(b, "leaves (0x70B5)")
			_ = b.send(session.OpStallLeave, nil)
		}
	}()
}

// stallSaw is a spawn record's stall (InteractMode 4).
func (b *bot) stallSaw(rec pcspawn.Record) {
	if rec.InteractMode == 4 {
		stallLog(b, "sees %s stalling (spawn): %q, booth %d", rec.Name, rec.StallName, rec.StallDecoration)
		b.stallSeen(rec.Name, rec.UID)
	}
}

// noteStall prints every stall message and follows 0x30B8.
func (b *bot) noteStall(op uint16, data []byte) {
	switch op {
	case session.OpInventoryListResult:
		if r, err := session.DecodeInventoryListResult(data); err == nil {
			botStall.mu.Lock()
			if botStall.qty == nil {
				botStall.qty = map[int]int{}
			}
			for _, sl := range r.Slots {
				botStall.qty[sl.Slot] = int(sl.Quantity)
			}
			botStall.mu.Unlock()
		}
	case session.OpStallAppear:
		if len(data) >= 6 {
			uid := binary.LittleEndian.Uint32(data)
			n := int(binary.LittleEndian.Uint16(data[4:]))
			name := ""
			if len(data) >= 6+n {
				name = string(data[6 : 6+n])
			}
			stallLog(b, "0x30B8 stall of %d: %q % x", uid, name, data)
			b.mu.Lock()
			who := ""
			for nm, id := range b.seen {
				if uint32(id) == uid {
					who = nm
				}
			}
			b.mu.Unlock()
			if who != "" {
				b.stallSeen(who, uid)
			}
		}
	case session.OpStallOpenResult, session.OpStallCloseResult, session.OpStallEnterResult, session.OpStallBuyResult,
		session.OpStallLeaveResult, session.OpStallUpdateResult, session.OpStallEvent, session.OpStallGone, session.OpStallRenamed:
		stallLog(b, "message %#04x % x", op, data)
	case session.OpChatUpdate:
		if u, err := session.DecodeChatUpdate(data); err == nil && u.Type == session.ChatStall {
			stallLog(b, "stall chat %s: %s", u.Sender, u.Message)
		}
	}
}
