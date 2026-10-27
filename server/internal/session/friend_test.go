package session

import (
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/friend"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 834: friends on the retail wire (friend.go, docs/protocol/friends.md).

func TestFriendWireLayouts(t *testing.T) {
	check := func(what string, got, want []byte) {
		t.Helper()
		if !bytes.Equal(got, want) {
			t.Errorf("%s: % x, want % x", what, got, want)
		}
	}
	check("0xB302 {2, 0x6408}", EncodeFriendAskFailed(FriendCodeFullList, 0, ""), []byte{2, 0x08, 0x64})
	check("0xB302 {2, 0x640b, reason, name}", EncodeFriendAskFailed(FriendCodeRefused, 2, "Bo"),
		[]byte{2, 0x0b, 0x64, 2, 2, 0, 'B', 'o'})
	check("0x7302 to the target", EncodeFriendRequest(7, 9, "Al"), []byte{7, 0, 0, 0, 9, 0, 0, 0, 2, 0, 'A', 'l'})
	check("0x3305", EncodeFriendList([]FriendEntry{{CharacterID: 5, Name: "Al", RefObjID: 1907, State: FriendOffline}}),
		[]byte{1, 5, 0, 0, 0, 2, 0, 'A', 'l', 0x73, 0x07, 0, 0, 1})
	check("0x3B07 kind 2", EncodeFriendAdded(5, "Al", 1907), []byte{2, 5, 0, 0, 0, 2, 0, 'A', 'l', 0x73, 0x07, 0, 0})
	check("0x3B07 kind 3", EncodeFriendRemoved(5), []byte{3, 5, 0, 0, 0})
	check("0x3B07 kind 4", EncodeFriendState(5, FriendOnline), []byte{4, 5, 0, 0, 0, 0})
	check("0xB304 ok", EncodeFriendDeleteResult(5, 0), []byte{1, 5, 0, 0, 0})
	check("0xB304 refused", EncodeFriendDeleteResult(0, 3), []byte{2, 3, 0})
}

// friendFixture is Aria and Bram in the world with the friend handler. The
// runtime is put in place after both have entered, so the fixture's own
// spawn reads see no friend list, and taken away after the test (it is the
// package's one global, and other tests' entries must not send lists).
func friendFixture(t *testing.T, store friend.Store) (*deadWorldFixture, *friendRuntime) {
	t.Helper()
	var rt *friendRuntime
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		h := FriendHandler(chars, store, hub)
		rt = friendRT.Swap(nil)
		return h
	})
	friendRT.Store(rt)
	t.Cleanup(func() { friendRT.Store(nil) })
	return f, rt
}

func askFriend(f *deadWorldFixture, t *testing.T, conn net.Conn, name string) {
	t.Helper()
	f.send(t, conn, OpFriendAsk, appendFriendStr(nil, name))
}

func answerFriend(f *deadWorldFixture, t *testing.T, conn net.Conn, request []byte, answer byte) {
	t.Helper()
	f.send(t, conn, OpFriendAnswer, append(append([]byte{}, request[:8]...), answer))
}

// Aria asks Bram; he gets the request box's message and accepts; both get
// the kind-2 push with the other's id, name and model.
func TestFriendAskAndAccept(t *testing.T) {
	f, _ := friendFixture(t, friend.NewMemStore())
	askFriend(f, t, f.connA, "Bram")
	req := nextOp(t, f.connB, f.rB, OpFriendAsk).Data
	if binary.LittleEndian.Uint32(req[4:]) != uint32(f.aria) || !bytes.Equal(req[8:], appendFriendStr(nil, "Aria")) {
		t.Fatalf("the request % x: want Aria's id and name", req)
	}
	answerFriend(f, t, f.connB, req, 1)
	a := nextOp(t, f.connA, f.rA, OpMessengerPush).Data
	b := nextOp(t, f.connB, f.rB, OpMessengerPush).Data
	if a[0] != MessengerAdded || binary.LittleEndian.Uint32(a[1:]) != uint32(f.bram) || !bytes.Equal(a[5:11], appendFriendStr(nil, "Bram")) {
		t.Errorf("Aria's push % x: want kind 2 Bram", a)
	}
	if b[0] != MessengerAdded || binary.LittleEndian.Uint32(b[1:]) != uint32(f.aria) || !bytes.Equal(b[5:11], appendFriendStr(nil, "Aria")) {
		t.Errorf("Bram's push % x: want kind 2 Aria", b)
	}
	if len(a) != 15 || binary.LittleEndian.Uint32(a[11:]) == 0 {
		t.Errorf("the push carries no model id: % x", a)
	}
	// Asked again: on the list already (the asker's check, 0x6409).
	askFriend(f, t, f.connA, "Bram")
	if got := nextOp(t, f.connA, f.rA, OpFriendAskFailed).Data; !bytes.Equal(got, EncodeFriendAskFailed(FriendCodeAlreadyFriend, 0, "")) {
		t.Errorf("asking a friend: % x, want 0x6409", got)
	}
	// From the other side the target's check answers the same.
	askFriend(f, t, f.connB, "Aria")
	if got := nextOp(t, f.connB, f.rB, OpFriendAskFailed).Data; !bytes.Equal(got, EncodeFriendAskFailed(FriendCodeAlreadyFriend, 0, "")) {
		t.Errorf("asking back: % x, want 0x6409", got)
	}
}

// The asker's checks in their order, and the target's.
func TestFriendAskRefusals(t *testing.T) {
	store := friend.NewMemStore()
	f, _ := friendFixture(t, store)
	for _, c := range []struct {
		name string
		code uint16
	}{
		{"", friendCodeFail},
		{"Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", friendCodeFail}, // 33
		{"Aria", friendCodeBadName},
		{"Br'am", friendCodeBadName},
		{"Nobody", FriendCodeUnknownUser},
		{"bram", FriendCodeUnknownUser}, // names are case-sensitive here
	} {
		askFriend(f, t, f.connA, c.name)
		if got := nextOp(t, f.connA, f.rA, OpFriendAskFailed).Data; !bytes.Equal(got, EncodeFriendAskFailed(c.code, 0, "")) {
			t.Errorf("asking %q: % x, want code %#x", c.name, got, c.code)
		}
	}
	ctx := context.Background()
	for i := int64(100); i < 100+friend.MaxFriends; i++ {
		if err := store.AddFriendship(ctx, f.bram, "Bram", i, "X"); err != nil {
			t.Fatal(err)
		}
	}
	askFriend(f, t, f.connA, "Bram")
	if got := nextOp(t, f.connA, f.rA, OpFriendAskFailed).Data; !bytes.Equal(got, EncodeFriendAskFailed(FriendCodeTargetFull, 0, "")) {
		t.Errorf("the target's list full: % x, want 0x640f", got)
	}
	askFriend(f, t, f.connB, "Aria")
	if got := nextOp(t, f.connB, f.rB, OpFriendAskFailed).Data; !bytes.Equal(got, EncodeFriendAskFailed(FriendCodeFullList, 0, "")) {
		t.Errorf("the asker's list full: % x, want 0x6408", got)
	}
}

// Refuse: both get 0xB302 {2, 0x640b, 0, name}; the request's job is gone.
func TestFriendRefuse(t *testing.T) {
	f, _ := friendFixture(t, friend.NewMemStore())
	askFriend(f, t, f.connA, "Bram")
	req := nextOp(t, f.connB, f.rB, OpFriendAsk).Data
	answerFriend(f, t, f.connB, req, 0)
	want := EncodeFriendAskFailed(FriendCodeRefused, FriendReasonRefused, "Bram")
	if got := nextOp(t, f.connA, f.rA, OpFriendAskFailed).Data; !bytes.Equal(got, want) {
		t.Errorf("the asker: % x, want % x", got, want)
	}
	if got := nextOp(t, f.connB, f.rB, OpFriendAskFailed).Data; !bytes.Equal(got, want) {
		t.Errorf("the refuser (retail's quirk): % x, want % x", got, want)
	}
	// A second answer to the same request does nothing.
	answerFriend(f, t, f.connB, req, 1)
	noOp(t, f.connA, f.rA, OpMessengerPush)
}

// Nobody answers: after the wait both get reason 2.
func TestFriendRequestTimesOut(t *testing.T) {
	saved := FriendRequestWait
	FriendRequestWait = 150 * time.Millisecond
	t.Cleanup(func() { FriendRequestWait = saved })
	f, _ := friendFixture(t, friend.NewMemStore())
	askFriend(f, t, f.connA, "Bram")
	nextOp(t, f.connB, f.rB, OpFriendAsk)
	want := EncodeFriendAskFailed(FriendCodeRefused, FriendReasonTimeout, "Bram")
	if got := nextOp(t, f.connA, f.rA, OpFriendAskFailed).Data; !bytes.Equal(got, want) {
		t.Errorf("the asker: % x, want % x", got, want)
	}
	if got := nextOp(t, f.connB, f.rB, OpFriendAskFailed).Data; !bytes.Equal(got, want) {
		t.Errorf("the target: % x, want % x", got, want)
	}
}

// An answer naming another asker, or from someone the request did not go
// to, is no answer.
func TestFriendAnswerMustMatch(t *testing.T) {
	f, _ := friendFixture(t, friend.NewMemStore())
	askFriend(f, t, f.connA, "Bram")
	req := nextOp(t, f.connB, f.rB, OpFriendAsk).Data
	bad := append([]byte{}, req[:8]...)
	binary.LittleEndian.PutUint32(bad[4:], uint32(f.bram))
	f.send(t, f.connB, OpFriendAnswer, append(bad, 1))
	answerFriend(f, t, f.connA, req, 1) // Aria answering her own request
	noOp(t, f.connA, f.rA, OpMessengerPush)
	answerFriend(f, t, f.connB, req, 1)
	if got := nextOp(t, f.connA, f.rA, OpMessengerPush).Data; got[0] != MessengerAdded {
		t.Errorf("the real answer: % x", got)
	}
}

// Delete: the deleter gets kind 3 then 0xB304 {1, id}; the other side kind
// 3; a name not on the list is refused 3.
func TestFriendDelete(t *testing.T) {
	store := friend.NewMemStore()
	f, _ := friendFixture(t, store)
	if err := store.AddFriendship(context.Background(), f.aria, "Aria", f.bram, "Bram"); err != nil {
		t.Fatal(err)
	}
	f.send(t, f.connA, OpFriendDelete, binary.LittleEndian.AppendUint32(nil, uint32(f.bram)))
	if got := nextOp(t, f.connA, f.rA, OpMessengerPush).Data; !bytes.Equal(got, EncodeFriendRemoved(uint32(f.bram))) {
		t.Errorf("the deleter's push % x", got)
	}
	if got := nextOp(t, f.connA, f.rA, OpFriendDeleteResult).Data; !bytes.Equal(got, EncodeFriendDeleteResult(uint32(f.bram), 0)) {
		t.Errorf("0xB304 % x", got)
	}
	if got := nextOp(t, f.connB, f.rB, OpMessengerPush).Data; !bytes.Equal(got, EncodeFriendRemoved(uint32(f.aria))) {
		t.Errorf("the other side's push % x", got)
	}
	if l, _ := store.ListFriends(context.Background(), f.bram); len(l) != 0 {
		t.Errorf("Bram still lists %+v", l)
	}
	f.send(t, f.connA, OpFriendDelete, binary.LittleEndian.AppendUint32(nil, uint32(f.bram)))
	if got := nextOp(t, f.connA, f.rA, OpFriendDeleteResult).Data; !bytes.Equal(got, EncodeFriendDeleteResult(0, 3)) {
		t.Errorf("deleting a non-friend: % x, want {2, 3}", got)
	}
}

// The world entry's list (state 0 for a friend in the game) and the log on
// and off pushes.
func TestFriendListAndLogOnOff(t *testing.T) {
	store := friend.NewMemStore()
	f, _ := friendFixture(t, store)
	ctx := context.Background()
	if err := store.AddFriendship(ctx, f.aria, "Aria", f.bram, "Bram"); err != nil {
		t.Fatal(err)
	}
	if err := store.AddFriendship(ctx, f.aria, "Aria", 999, "Away"); err != nil {
		t.Fatal(err)
	}
	ea, _ := f.hub.EntityByCharacterID(f.aria)
	aria, _ := f.chars.GetByID(ctx, f.aria)
	friendAfterEnter(ctx, ea.Session, aria)
	list := nextOp(t, f.connA, f.rA, OpFriendList).Data
	bramChar, _ := f.chars.GetByID(ctx, f.bram)
	bramRef, _ := modelOf(bramChar)
	want := EncodeFriendList([]FriendEntry{
		{CharacterID: 999, Name: "Away", State: FriendOffline},
		{CharacterID: uint32(f.bram), Name: "Bram", RefObjID: bramRef, State: FriendOnline},
	})
	if !bytes.Equal(list, want) {
		t.Errorf("0x3305 % x, want % x", list, want)
	}
	if got := nextOp(t, f.connB, f.rB, OpMessengerPush).Data; !bytes.Equal(got, EncodeFriendState(uint32(f.aria), FriendOnline)) {
		t.Errorf("Bram hears % x, want Aria logged on", got)
	}
	FriendDisconnectHandler(f.hub)(ea.Session)
	if got := nextOp(t, f.connB, f.rB, OpMessengerPush).Data; !bytes.Equal(got, EncodeFriendState(uint32(f.aria), FriendOffline)) {
		t.Errorf("Bram hears % x, want Aria logged off", got)
	}
}
