package guild

import (
	"bytes"
	"context"
	"errors"
	"testing"
)

var (
	_ UnionStore = (*MemStore)(nil)
	_ UnionStore = (*SQLStore)(nil)
)

type unionTestStore interface {
	Store
	UnionStore
}

// Round 842: unions -- formed by a join to a host with none (slot 0 the
// host), the refusals, a leave freeing its slot, a union under two guilds
// dissolved, a disbanded guild leaving its union -- on both stores.
func TestRound842UnionsMem(t *testing.T) { testRound842Unions(t, NewMemStore()) }

func TestRound842UnionsSQL(t *testing.T) { testRound842Unions(t, openTestSQLStore(t)) }

func testRound842Unions(t *testing.T, s unionTestStore) {
	t.Helper()
	ctx := context.Background()
	mk := func(name string, leader int64) *Guild {
		g, err := s.Create(ctx, name, leader, name+"Master")
		if err != nil {
			t.Fatal(err)
		}
		return g
	}
	a, b, c, d := mk("Alpha", 1), mk("Beta", 2), mk("Gamma", 3), mk("Delta", 4)
	if u, err := s.UnionOf(ctx, a.ID); u != nil || err != nil {
		t.Fatalf("a new guild's union: %v %v", u, err)
	}
	if _, err := s.JoinUnion(ctx, a.ID, a.ID); !errors.Is(err, ErrUnionSameGuild) {
		t.Fatalf("own guild: %v", err)
	}
	if _, err := s.JoinUnion(ctx, a.ID, 999999); !errors.Is(err, ErrGuildNotFound) {
		t.Fatalf("no such host: %v", err)
	}
	u, err := s.JoinUnion(ctx, b.ID, a.ID)
	if err != nil {
		t.Fatal(err)
	}
	if u.LeaderGuildID() != a.ID || u.Slots[1] != b.ID || u.Count() != 2 || !u.Has(a.ID) || !u.Has(b.ID) || u.Has(c.ID) {
		t.Fatalf("formed: %+v", u)
	}
	if _, err := s.JoinUnion(ctx, b.ID, c.ID); !errors.Is(err, ErrUnionAlreadyMember) {
		t.Fatalf("a member joining another: %v", err)
	}
	if u, err = s.JoinUnion(ctx, c.ID, b.ID); err != nil || u.Slots[2] != c.ID {
		t.Fatalf("a third through a member: %+v %v", u, err)
	}
	for _, id := range []int64{a.ID, b.ID, c.ID} {
		if got, _ := s.UnionOf(ctx, id); got == nil || got.ID != u.ID {
			t.Fatalf("UnionOf(%d): %+v", id, got)
		}
	}
	// B leaves: its slot is freed, not compacted; D takes it.
	before, after, err := s.LeaveUnion(ctx, b.ID)
	if err != nil || before.Count() != 3 || after == nil || after.Slots[1] != 0 || after.Slots[2] != c.ID {
		t.Fatalf("leave: %+v -> %+v, %v", before, after, err)
	}
	if _, _, err := s.LeaveUnion(ctx, b.ID); !errors.Is(err, ErrNoUnion) {
		t.Fatalf("leaving twice: %v", err)
	}
	if u, err = s.JoinUnion(ctx, d.ID, a.ID); err != nil || u.Slots[1] != d.ID {
		t.Fatalf("D into the freed slot: %+v %v", u, err)
	}
	// D disbands: it leaves the union with it.
	if _, err := s.Disband(ctx, d.ID); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.UnionOf(ctx, a.ID); got == nil || got.Count() != 2 || got.Has(d.ID) {
		t.Fatalf("after D's disband: %+v", got)
	}
	// C leaves: one guild left, the union is dissolved.
	if _, after, err = s.LeaveUnion(ctx, c.ID); err != nil || after != nil {
		t.Fatalf("the second-last leave: %+v %v", after, err)
	}
	if got, _ := s.UnionOf(ctx, a.ID); got != nil {
		t.Fatalf("A is still in %+v", got)
	}
	// A full union refuses the ninth guild.
	host := mk("Host", 10)
	for i := 0; i < MaxAllianceGuilds-1; i++ {
		g := mk("Member"+string(rune('A'+i)), int64(20+i))
		if _, err := s.JoinUnion(ctx, g.ID, host.ID); err != nil {
			t.Fatalf("member %d: %v", i, err)
		}
	}
	if _, err := s.JoinUnion(ctx, b.ID, host.ID); !errors.Is(err, ErrUnionFull) {
		t.Fatalf("the ninth: %v", err)
	}
	if UnionCode(ErrUnionFull) != ErrAllianceFull || UnionCode(ErrUnionAlreadyMember) != ErrAllianceTargetHasAlliance {
		t.Fatal("UnionCode")
	}
	// The last member of a guild leaving deletes the guild and its slot.
	if _, _, err := s.Leave(ctx, 10); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.UnionOf(ctx, a.ID); got != nil {
		t.Fatalf("A: %+v", got)
	}
	g0, _ := s.GetByCharacter(ctx, 20)
	if got, _ := s.UnionOf(ctx, g0.ID); got == nil || got.Count() != MaxAllianceGuilds-1 || got.Has(host.ID) {
		t.Fatalf("after the host guild emptied: %+v", got)
	}
}

// Round 842: 0x3102 and 0x38F5 types 0x0d / 0x12 as the client's readers
// take them (FUN_0099a810; FUN_00887330's cases at 0x887ae9 / 0x887e3b).
func TestRound842UnionBytes(t *testing.T) {
	u := &Union{ID: 7, CrestRev: 3}
	u.Slots[0], u.Slots[1] = 11, 12
	e := []UnionEntry{
		{GuildID: 11, Name: "Ab", Level: 2, MasterName: "M", MasterModel: 0x0707, Members: 5},
		{GuildID: 12, Name: "C", Level: 4, MasterName: "Nn", MasterModel: 0x0708, Members: 1},
	}
	got := EncodeUnionInfo(u, e)
	want := []byte{
		7, 0, 0, 0, 3, 0, 0, 0, 11, 0, 0, 0, 2,
		11, 0, 0, 0, 2, 0, 'A', 'b', 2, 1, 0, 'M', 7, 7, 0, 0, 5,
		12, 0, 0, 0, 1, 0, 'C', 4, 2, 0, 'N', 'n', 8, 7, 0, 0, 1,
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("0x3102:\n got % x\nwant % x", got, want)
	}
	if got := EncodeUnionInfo(nil, nil); !bytes.Equal(got, make([]byte, 13)) {
		t.Fatalf("no union: % x", got)
	}
	if got := EncodeUnionJoined(e[1]); !bytes.Equal(got, append([]byte{0x0d}, want[30:]...)) {
		t.Fatalf("type 0x0d: % x", got)
	}
	if got := EncodeUnionOut(UnionOutLeft, 12); !bytes.Equal(got, []byte{0x12, 1, 12, 0, 0, 0}) {
		t.Fatalf("type 0x12 left: % x", got)
	}
	if got := EncodeUnionOut(UnionOutBroken, 12); !bytes.Equal(got, []byte{0x12, 3}) {
		t.Fatalf("type 0x12 broken: % x", got)
	}
	g := &Guild{ID: 11, Name: "Ab", Level: 2, LeaderID: 5, Members: []Member{{CharacterID: 6, Name: "X"}, {CharacterID: 5, Name: "M", Role: RoleLeader}}}
	if got := EntryOf(g, func(id int64) uint32 { return uint32(id) * 10 }); got.MasterName != "M" || got.MasterModel != 50 || got.Members != 2 {
		t.Fatalf("EntryOf: %+v", got)
	}
}
