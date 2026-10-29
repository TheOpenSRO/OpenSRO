package session

import (
	"bytes"
	"context"
	"encoding/binary"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/namefilter"
	"github.com/TheOpenSRO/OpenSRO/server/internal/stall"
)

// Round 840, lane B: the chat and trade bans (restriction slots 4 and 3,
// FUN_004f0a00), the quest block's stall bit, and the title's word filter,
// on the stall fixture (Aria alice, Bram bob).

func (f *stallFixture) punish(t *testing.T, user string, typ account.PunishmentType, end time.Time) {
	t.Helper()
	ctx := context.Background()
	acc, err := f.accounts.AccountByName(ctx, user)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.accounts.AddPunishment(ctx, account.Punishment{AccountID: acc.ID, Type: typ, Executor: "gm",
		Guide: "test", BeginAt: time.Now().Add(-time.Minute), EndAt: end}); err != nil {
		t.Fatal(err)
	}
	ForgetRestrictions(acc.ID)
}

func setupRestrictionTest(t *testing.T) *stallFixture {
	t.Helper()
	f := setupStallTest(t)
	SetRestrictionStore(f.accounts)
	t.Cleanup(func() { SetRestrictionStore(nil) })
	return f
}

func TestRestrictionWire(t *testing.T) {
	end := time.Date(2026, 11, 3, 14, 25, 9, 0, time.Local)
	got := EncodeRestriction(RestrictTrade, end)
	v := binary.LittleEndian.Uint32(got[1:])
	if got[0] != 1 || len(got) != 5 {
		t.Fatalf("0x3405 % x", got)
	}
	// The client's reading (c:0x86e5b0): year (v & 0x3f) + 2000, month,
	// day, hour, minute.
	if y, mo, d, h, mi := int(v&0x3f)+2000, int(v>>6&0xf), int(v>>10&0x1f), int(v>>15&0x1f), int(v>>20&0x3f); y != 2026 || mo != 11 || d != 3 || h != 14 || mi != 25 {
		t.Fatalf("unpacked %d-%d-%d %d:%d", y, mo, d, h, mi)
	}
	if v>>26 != 9 {
		t.Fatalf("seconds %d", v>>26)
	}
	if len(chatBannedStallSuffixes) != 11 || chatBannedStallSuffixes[1] != "'s Shop" {
		t.Fatalf("the suffixes %q", chatBannedStallSuffixes)
	}
	for i := 0; i < 50; i++ {
		n := chatBannedStallName("Aria")
		ok := false
		for _, s := range chatBannedStallSuffixes {
			if n == "Aria"+s {
				ok = true
			}
		}
		if !ok {
			t.Fatalf("chatBannedStallName = %q", n)
		}
	}
}

// A trade-banned player: the stall open and enter and the exchange request
// answer 0x3405 {1, end} and nothing else (s:0x515f21, 0x51627b, 0x515530).
func TestTradeBanRefusesStallsAndExchange(t *testing.T) {
	f := setupRestrictionTest(t)
	end := time.Now().Add(2 * time.Hour).Truncate(time.Second)
	f.punish(t, "alice", account.PunishTrade, end)
	want := EncodeRestriction(RestrictTrade, end)

	f.send(t, "A", OpStallOpen, stallStr("Aria's stall"))
	if got := f.next(t, "A", OpRestriction); !bytes.Equal(got, want) {
		t.Fatalf("open: 0x3405 % x, want % x", got, want)
	}
	f.none(t, "A", OpStallOpenResult)
	if f.stalls.Mode(f.ariaID) != stall.ModeNone {
		t.Fatal("a trade-banned player opened a stall")
	}

	f.send(t, "A", OpExchangeRequest, binary.LittleEndian.AppendUint32(nil, uint32(f.bramID)))
	if got := f.next(t, "A", OpRestriction); !bytes.Equal(got, want) {
		t.Fatalf("exchange: 0x3405 % x", got)
	}
	f.none(t, "B", OpRequestBox)

	// Bram's stall: Aria may not enter.
	f.send(t, "B", OpStallOpen, stallStr("Bram's stall"))
	f.next(t, "B", OpStallOpenResult)
	f.send(t, "A", OpStallEnter, binary.LittleEndian.AppendUint32(nil, uint32(f.bramID)))
	if got := f.next(t, "A", OpRestriction); !bytes.Equal(got, want) {
		t.Fatalf("enter: 0x3405 % x", got)
	}
	f.none(t, "A", OpStallEnterResult)

	// The chat ban is the other slot: Aria still chats.
	f.send(t, "A", OpChatSend, (&ChatSendRequest{Type: ChatAll, Index: 1, Message: "hi"}).Encode())
	if r, err := DecodeChatResult(f.next(t, "A", OpChatResult)); err != nil || !r.OK {
		t.Fatalf("a trade-banned player's chat: %+v %v", r, err)
	}

	// Ended: the GM's unban drops the cache, and the open goes through.
	acc, _ := f.accounts.AccountByName(context.Background(), "alice")
	if n, _ := f.accounts.EndPunishments(context.Background(), acc.ID, time.Now(), account.PunishTrade); n != 1 {
		t.Fatalf("ended %d", n)
	}
	ForgetRestrictions(acc.ID)
	f.send(t, "A", OpStallOpen, stallStr("Aria's stall"))
	if got := f.next(t, "A", OpStallOpenResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("after the unban 0xB0B1 % x", got)
	}
}

// A chat-banned player: every chat line is dropped with 0x3405 {0, end} and
// no result (s:0x4b17ce); the stall opens under the name and a suffix, the
// owner told the ban (s:0x471db6).
func TestChatBanDropsChatAndRenamesTheStall(t *testing.T) {
	f := setupRestrictionTest(t)
	end := time.Now().Add(30 * time.Minute).Truncate(time.Second)
	f.punish(t, "alice", account.PunishChat, end)
	want := EncodeRestriction(RestrictChat, end)

	f.send(t, "A", OpChatSend, (&ChatSendRequest{Type: ChatAll, Index: 1, Message: "hello"}).Encode())
	if got := f.next(t, "A", OpRestriction); !bytes.Equal(got, want) {
		t.Fatalf("chat: 0x3405 % x, want % x", got, want)
	}
	f.none(t, "A", OpChatResult)
	f.none(t, "B", OpChatUpdate)

	f.send(t, "A", OpStallOpen, stallStr("Cheap goods"))
	if got := f.next(t, "A", OpRestriction); !bytes.Equal(got, want) {
		t.Fatalf("open: 0x3405 % x", got)
	}
	app := f.next(t, "B", OpStallAppear)
	name, _, _ := stallReadString(app[4:])
	if !strings.HasPrefix(name, "Aria") || name == "Aria" || strings.Contains(name, "Cheap") {
		t.Fatalf("the chat-banned stall's name %q", name)
	}
	if got := f.next(t, "A", OpStallOpenResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("0xB0B1 % x", got)
	}
	if s, _ := f.stalls.Get(f.ariaID); s.Name != name {
		t.Fatalf("the hub's name %q, the wire's %q", s.Name, name)
	}
	// The stall chat is chat too.
	f.send(t, "A", OpChatSend, (&ChatSendRequest{Type: ChatStall, Index: 2, Message: "buy"}).Encode())
	f.next(t, "A", OpRestriction)
	f.none(t, "A", OpChatUpdate)
}

// An expired ban holds nothing; an infinite one is sent as its begin plus
// 100 years (the console's infinite date).
func TestRestrictionEndsAndInfinite(t *testing.T) {
	f := setupRestrictionTest(t)
	f.punish(t, "alice", account.PunishTrade, time.Now().Add(-time.Second))
	f.send(t, "A", OpStallOpen, stallStr("Aria's stall"))
	if got := f.next(t, "A", OpStallOpenResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("an ended ban refused: % x", got)
	}
	ctx := context.Background()
	bob, _ := f.accounts.AccountByName(ctx, "bob")
	begin := time.Now().Add(-time.Hour).Truncate(time.Second)
	if _, err := f.accounts.AddPunishment(ctx, account.Punishment{AccountID: bob.ID, Type: account.PunishTrade,
		Executor: "gm", Guide: "x", BeginAt: begin}); err != nil {
		t.Fatal(err)
	}
	ForgetRestrictions(bob.ID)
	f.send(t, "B", OpStallEnter, binary.LittleEndian.AppendUint32(nil, uint32(f.ariaID)))
	if got := f.next(t, "B", OpRestriction); !bytes.Equal(got, EncodeRestriction(RestrictTrade, begin.AddDate(100, 0, 0))) {
		t.Fatalf("the infinite ban's 0x3405 % x", got)
	}
}

// The quest block's stall bit: 0x3c32 at the open, 0x3c33 at the enter, in
// retail's order (after the trade ban, before the world check).
func TestQuestBlockRefusesTheStall(t *testing.T) {
	f := setupRestrictionTest(t)
	t.Cleanup(func() { questBlockReset(f.ariaID); questBlockReset(f.bramID) })
	f.send(t, "B", OpStallOpen, stallStr("Bram's stall"))
	f.next(t, "B", OpStallOpenResult)

	if got := QuestBlockSet(f.ariaID, 0x60000); got != 0x60000 {
		t.Fatalf("block %#x", got)
	}
	f.send(t, "A", OpStallOpen, stallStr("Aria's stall")) // another bit: no refusal
	if got := f.next(t, "A", OpStallOpenResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("0x60000 refused the open: % x", got)
	}
	f.send(t, "A", OpStallClose, nil)
	f.next(t, "A", OpStallCloseResult)

	QuestBlockSet(f.ariaID, QuestBlockStall)
	f.send(t, "A", OpStallOpen, stallStr("Aria's stall"))
	if got := f.next(t, "A", OpStallOpenResult); !bytes.Equal(got, stallResult(StallErrQuestOpen)) {
		t.Fatalf("open 0xB0B1 % x, want 0x3c32", got)
	}
	f.send(t, "A", OpStallEnter, binary.LittleEndian.AppendUint32(nil, uint32(f.bramID)))
	if got := f.next(t, "A", OpStallEnterResult); !bytes.Equal(got, stallResult(StallErrQuestEnter)) {
		t.Fatalf("enter 0xB0B3 % x, want 0x3c33", got)
	}
	// The trade ban comes first.
	f.punish(t, "alice", account.PunishTrade, time.Now().Add(time.Hour))
	f.send(t, "A", OpStallOpen, stallStr("Aria's stall"))
	f.next(t, "A", OpRestriction)
	f.none(t, "A", OpStallOpenResult)
	acc, _ := f.accounts.AccountByName(context.Background(), "alice")
	f.accounts.EndPunishments(context.Background(), acc.ID, time.Now(), account.PunishTrade)
	ForgetRestrictions(acc.ID)

	if got := QuestBlockRelease(f.ariaID, QuestBlockStall); got != 0x60000 {
		t.Fatalf("after the release %#x", got)
	}
	f.send(t, "A", OpStallEnter, binary.LittleEndian.AppendUint32(nil, uint32(f.bramID)))
	if got := f.next(t, "A", OpStallEnterResult); got[0] != 1 {
		t.Fatalf("released, the enter % x", got)
	}
}

// The title's word filter (f4, the client's c:0x8c3f10; OURS on the server
// too): 0x3c38 for the open and for the rename.
func TestStallTitleFilter(t *testing.T) {
	f := setupRestrictionTest(t)
	units := []rune("\ufeff#ALLOW_ID_TABLE\t0x0061\t0x007A\r\n" + strings.Repeat("\t", 24) + "cheap\t0\t0\t0\t1\t\r\n" +
		strings.Repeat("\t", 24) + "scam\t0\t0\t0\t2\t\r\n")
	var data []byte
	for _, r := range units {
		data = append(data, byte(r), byte(r>>8))
	}
	nf, err := namefilter.Load(data, 4)
	if err != nil {
		t.Fatal(err)
	}
	SetNameFilter(nf)
	t.Cleanup(func() { SetNameFilter(nil) })

	for _, bad := range []string{"cheap", "All CHEAP here", "no scams"} {
		f.send(t, "A", OpStallOpen, stallStr(bad))
		if got := f.next(t, "A", OpStallOpenResult); !bytes.Equal(got, stallResult(StallErrTitleFilter)) {
			t.Fatalf("%q: 0xB0B1 % x, want 0x3c38", bad, got)
		}
	}
	f.openStall(t)
	f.send(t, "A", OpStallUpdate, append([]byte{StallUpdateRename}, stallStr("Cheap stuff")...))
	if got := f.next(t, "A", OpStallUpdateResult); !bytes.Equal(got, stallResult(StallErrTitleFilter)) {
		t.Fatalf("rename % x, want 0x3c38", got)
	}
	f.send(t, "A", OpStallUpdate, append([]byte{StallUpdateRename}, stallStr("Cheaper stuff")...))
	if got := f.next(t, "A", OpStallUpdateResult); !bytes.Equal(got, []byte{1, StallUpdateRename}) {
		t.Fatalf("a clean rename % x", got)
	}
}
