package main

// Round 834 (QA): the bot's friend and exchange steps, on the retail wire
// (session/friend.go, session/exchange.go). Every step waits -social-delay
// first, so a test sees the messages in the order a person's clicks give
// them, network delays included.

import (
	"encoding/binary"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

var botGMLines string

var botSocial struct {
	friendAsk      string
	friendAnswer   string // accept, refuse or "" (no answer)
	exchangeWith   string
	exchangeAnswer string // accept, refuse or ""
	exchangeSlots  string // bag indexes, "0,1", or item ids "i71,i4"
	exchangeGold   int64
	delay          time.Duration
	askAfter       time.Duration // -exchange-ask-after: the wait before 0x7081 once in view
	confirmWhen    string        // -exchange-confirm: first, second or never
	hold           time.Duration // -exchange-hold: the wait before offering

	mu            sync.Mutex
	askedFriend   bool
	askedExchange bool
	offered       bool // the offer is in; "second" confirms after it
	confirmed     bool
	partnerDone   bool
	approved      bool
	confirmSent   bool
}

func socialLog(b *bot, format string, args ...any) {
	fmt.Printf("%s [%s] SOCIAL %s\n", time.Now().Format("15:04:05.000"), b.name, fmt.Sprintf(format, args...))
}

func (b *bot) later(f func()) {
	go func() {
		time.Sleep(botSocial.delay)
		f()
	}()
}

// socialSteps runs when a player comes into view.
func (b *bot) socialSteps(name string, id int64) {
	s := &botSocial
	s.mu.Lock()
	askFriend := s.friendAsk != "" && name == s.friendAsk && !s.askedFriend
	askExchange := s.exchangeWith != "" && name == s.exchangeWith && !s.askedExchange
	if askFriend {
		s.askedFriend = true
	}
	if askExchange {
		s.askedExchange = true
	}
	s.mu.Unlock()
	if askFriend {
		b.later(func() {
			socialLog(b, "asks %s to be friends (0x7302)", name)
			out := binary.LittleEndian.AppendUint16(nil, uint16(len(name)))
			_ = b.send(session.OpFriendAsk, append(out, name...))
		})
	}
	if askExchange {
		b.later(func() {
			time.Sleep(s.askAfter)
			socialLog(b, "asks %s (%d) to exchange (0x7081)", name, id)
			_ = b.send(session.OpExchangeRequest, binary.LittleEndian.AppendUint32(nil, uint32(id)))
		})
	}
}

// bagSlots is the bot's bag (0x0031), item id -> bag index; filled by
// noteSocial when the list comes.
var bagSlots = struct {
	sync.Mutex
	byItem map[int64]int
}{byItem: map[int64]int{}}

func (b *bot) offerAndConfirm() {
	s := &botSocial
	time.Sleep(s.hold)
	_ = b.send(session.OpInventoryList, (&session.CharacterNameRequest{Name: b.name}).Encode())
	time.Sleep(s.delay)
	for _, f := range strings.Split(s.exchangeSlots, ",") {
		if f = strings.TrimSpace(f); f == "" {
			continue
		}
		var n int
		if strings.HasPrefix(f, "i") {
			id, err := strconv.ParseInt(f[1:], 10, 64)
			if err != nil {
				continue
			}
			bagSlots.Lock()
			idx, ok := bagSlots.byItem[id]
			bagSlots.Unlock()
			if !ok {
				socialLog(b, "has no item %d in its bag", id)
				continue
			}
			n = idx
		} else {
			var err error
			if n, err = strconv.Atoi(f); err != nil {
				continue
			}
		}
		time.Sleep(s.delay)
		socialLog(b, "offers bag slot %d (0x7034 {4, %d})", n, n+session.ItemWireBagOffset)
		_ = b.send(session.OpItemMove, []byte{session.ItemMoveExchangeAdd, byte(n + session.ItemWireBagOffset)})
	}
	if s.exchangeGold > 0 {
		time.Sleep(s.delay)
		socialLog(b, "offers %d gold (0x7034 {0xd})", s.exchangeGold)
		_ = b.send(session.OpItemMove, binary.LittleEndian.AppendUint64([]byte{session.ItemMoveExchangeGold}, uint64(s.exchangeGold)))
	}
	s.mu.Lock()
	s.offered = true
	s.mu.Unlock()
	b.maybeConfirm()
}

// maybeConfirm sends 0x7082 when -exchange-confirm says it is time: first
// right after the offer, second once the partner's 0x3086 came too.
func (b *bot) maybeConfirm() {
	s := &botSocial
	s.mu.Lock()
	go1 := s.offered && !s.confirmSent && (s.confirmWhen == "first" || (s.confirmWhen == "second" && s.partnerDone))
	if go1 {
		s.confirmSent = true
	}
	s.mu.Unlock()
	if go1 {
		b.later(func() {
			socialLog(b, "confirms (0x7082)")
			_ = b.send(session.OpExchangeConfirm, nil)
		})
	}
}

func (b *bot) maybeApprove() {
	s := &botSocial
	s.mu.Lock()
	go1 := s.confirmed && s.partnerDone && !s.approved
	if go1 {
		s.approved = true
	}
	s.mu.Unlock()
	if go1 {
		b.later(func() {
			socialLog(b, "approves (0x7083)")
			_ = b.send(session.OpExchangeApprove, nil)
		})
	}
}

// noteSocial reads the friend and exchange messages.
func (b *bot) noteSocial(op uint16, data []byte) {
	s := &botSocial
	switch op {
	case session.OpFriendAsk:
		if len(data) < 10 {
			return
		}
		socialLog(b, "friend request from %s (job %d)", string(data[10:]), binary.LittleEndian.Uint32(data))
		if s.friendAnswer == "" {
			return
		}
		ans := byte(0)
		if s.friendAnswer == "accept" {
			ans = 1
		}
		b.later(func() {
			socialLog(b, "answers the friend request %d (0x3303)", ans)
			_ = b.send(session.OpFriendAnswer, append(append([]byte{}, data[:8]...), ans))
		})
	case session.OpFriendAskFailed, session.OpMessengerPush, session.OpFriendList, session.OpFriendDeleteResult:
		socialLog(b, "friend message %#04x % x", op, data)
	case session.OpRequestBox:
		if len(data) < 5 || data[0] != 1 {
			return
		}
		socialLog(b, "exchange request from %d", binary.LittleEndian.Uint32(data[1:]))
		if s.exchangeAnswer == "" {
			return
		}
		ans := byte(0)
		if s.exchangeAnswer == "accept" {
			ans = 1
		}
		b.later(func() {
			socialLog(b, "answers the exchange request {1, %d} (0x3080)", ans)
			_ = b.send(session.OpRequestBox, []byte{1, ans})
		})
	case session.OpExchangeRequestResult, session.OpExchangeStarted:
		socialLog(b, "exchange message %#04x % x", op, data)
		if op == session.OpExchangeStarted || (len(data) > 0 && data[0] == 1) {
			s.mu.Lock()
			s.confirmed, s.partnerDone, s.approved = false, false, false
			s.mu.Unlock()
			go b.offerAndConfirm()
		}
	case session.OpExchangeConfirmResult:
		socialLog(b, "0xB082 % x", data)
		if len(data) > 0 && data[0] == 1 {
			s.mu.Lock()
			s.confirmed = true
			s.mu.Unlock()
			b.maybeApprove()
		}
	case session.OpExchangeConfirmed:
		socialLog(b, "the partner confirmed (0x3086)")
		s.mu.Lock()
		s.partnerDone = true
		s.mu.Unlock()
		b.maybeConfirm()
		b.maybeApprove()
	case session.OpInventoryListResult:
		if r, err := session.DecodeInventoryListResult(data); err == nil {
			bagSlots.Lock()
			for _, sl := range r.Slots {
				bagSlots.byItem[sl.ItemID] = sl.Slot
			}
			bagSlots.Unlock()
			socialLog(b, "bag %+v", r.Slots)
		}
	case session.OpExchangeOffer, session.OpExchangeUpdate, session.OpExchangeApproveResult,
		session.OpExchangeCancelResult, session.OpExchangeDone, session.OpExchangeClosed, session.OpItemMoveResult:
		socialLog(b, "exchange message %#04x % x", op, data)
	}
}
