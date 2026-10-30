package guild

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"testing"
	"time"
)

var (
	_ WarStore = (*MemStore)(nil)
	_ WarStore = (*SQLStore)(nil)
)

type warTestStore interface {
	Store
	WarStore
}

// Round 844: the war's rules as read -- the period word (m:0x435a80 and the
// GameServer's bounds), the kill points (s:0x5c721x), the victory table
// (m:0x781ab0), the two winners (m:0x43c320 at a kill, m:0x438430 by time).
func TestRound844WarRules(t *testing.T) {
	span, unl, ok := ParseWarPeriod(PackWarPeriod(1, 2, 30))
	if !ok || unl || span != 26*time.Hour+30*time.Minute {
		t.Fatalf("1d 2h 30m: %v %v %v", span, unl, ok)
	}
	if _, unl, ok := ParseWarPeriod(WarPeriodUnlimited); !ok || !unl {
		t.Fatal("0x7fffffff is unlimited")
	}
	for _, bad := range []uint32{PackWarPeriod(31, 0, 0), PackWarPeriod(0, 24, 0), PackWarPeriod(0, 0, 51)} {
		if _, _, ok := ParseWarPeriod(bad); ok {
			t.Errorf("0x%x passed the bounds", bad)
		}
	}
	// The client's own packing (c:0x71a810): day << 10 | hour << 15 | min << 20.
	if PackWarPeriod(1, 0, 10) != 0x400|10<<20 {
		t.Fatalf("pack: 0x%x", PackWarPeriod(1, 0, 10))
	}
	for _, c := range []struct {
		victim, killer int
		want           uint32
	}{
		{30, 30, 100}, {30, 36, 1}, {30, 35, 25}, {41, 30, 251}, {40, 30, 250}, {31, 30, 115},
	} {
		if got := WarKillPoints(c.victim, c.killer); got != c.want {
			t.Errorf("WarKillPoints(%d, %d) = %d, want %d", c.victim, c.killer, got, c.want)
		}
	}
	if WarVictoryPoints != [8]uint32{0, 5000, 10000, 50000, 100000, 150000, 250000, 300000} {
		t.Fatal("the victory table")
	}
	now := time.Now()
	w := War{GuildA: 1, GuildB: 2, VictoryIndex: 1, PointsA: 4999, EndTime: now.Add(time.Minute)}
	if _, won := w.WinnerByPoints(); won {
		t.Fatal("4999 of 5000 won")
	}
	w.PointsA = 5000
	if g, won := w.WinnerByPoints(); !won || g != 1 {
		t.Fatal("5000 did not win")
	}
	w = War{GuildA: 1, GuildB: 2, EndTime: now.Add(-time.Second)}
	if _, won := w.WinnerByTime(now); won {
		t.Fatal("a tie past the end was ended (it runs on)")
	}
	w.PointsB = 1
	if g, won := w.WinnerByTime(now); !won || g != 2 {
		t.Fatal("B ahead past the end did not win")
	}
	w.EndTime = time.Time{}
	if _, won := w.WinnerByTime(now); won || w.SecondsLeft(now) != WarPeriodUnlimited {
		t.Fatal("an endless war ended by time")
	}
}

// Round 844: the war's bytes as the client's readers take them (c:0x87ff10
// SGuildWarDef, c:0x887330's types, c:0x885920 the proclamation).
func TestRound844WarBytes(t *testing.T) {
	now := time.Unix(1000, 0)
	w := &War{ID: 7, VictoryIndex: 2, LodgedGold: 200000, EndTime: now.Add(90 * time.Second), GuildA: 3, GuildB: 4, PointsA: 100, PointsB: 15}
	e := []byte{7, 0, 0, 0, 90, 0, 0, 0, 2, 0x40, 0x0d, 3, 0, 3, 0, 0, 0, 4, 0, 0, 0, 100, 0, 0, 0, 15, 0, 0, 0}
	if got := EncodeHostileList([]HostileEntry{{War: w, EnemyName: "Beta"}, {}}, now); !bytes.Equal(got,
		append(append([]byte{2}, e...), 4, 0, 'B', 'e', 't', 'a', 0, 0, 0, 0)) {
		t.Fatalf("0x3109 % x", got)
	}
	if got := EncodeWarStarted(w, "Beta", now); !bytes.Equal(got, append(append([]byte{0x19}, e...), 4, 0, 'B', 'e', 't', 'a')) {
		t.Fatalf("0x19 % x", got)
	}
	if got := EncodeWarTime(w, now); !bytes.Equal(got, []byte{0x1f, 7, 0, 0, 0, 90, 0, 0, 0}) {
		t.Fatalf("0x1f % x", got)
	}
	if got := EncodeWarEnded(7, 4); !bytes.Equal(got, []byte{0x1c, 7, 0, 0, 0, 4, 0, 0, 0}) {
		t.Fatalf("0x1c % x", got)
	}
	if got := EncodeWarEnding(UpdateWarEndingBy, 7); !bytes.Equal(got, []byte{0x1b, 7, 0, 0, 0}) {
		t.Fatalf("0x1b % x", got)
	}
	if got := EncodeWarKill(1, 7, 100, 9, "Bram", ""); !bytes.Equal(got,
		[]byte{0x1d, 1, 7, 0, 0, 0, 100, 0, 0, 0, 9, 0, 0, 0, 4, 0, 'B', 'r', 'a', 'm'}) {
		t.Fatalf("0x1d % x", got)
	}
	if got := EncodeWarKill(1, 7, 100, 9, "", "Bram"); !bytes.Equal(got,
		[]byte{0x1d, 1, 7, 0, 0, 0, 100, 0, 0, 0, 9, 0, 0, 0, 0, 0, 4, 0, 'B', 'r', 'a', 'm'}) {
		t.Fatalf("0x1d with an alias % x", got)
	}
	dec := WarDeclaration{Target: "Beta", Period: PackWarPeriod(0, 0, 10), VictoryIndex: 1, Stake: 100000}
	raw := dec.Encode()
	want := []byte{4, 0, 'B', 'e', 't', 'a', 0}
	want = binary.LittleEndian.AppendUint32(want, 10<<20)
	want = append(want, 1)
	want = binary.LittleEndian.AppendUint32(want, 100000)
	if !bytes.Equal(raw, want) {
		t.Fatalf("0x7110 % x", raw)
	}
	if back, ok := DecodeWarDeclaration(raw); !ok || back != dec {
		t.Fatalf("decoded %+v", back)
	}
	if _, ok := DecodeWarDeclaration(raw[:len(raw)-1]); ok {
		t.Fatal("a short 0x7110 decoded")
	}
	p := EncodeWarProclamation(0x11, "Alpha", 0, 10<<20, 1, 100000)
	if !bytes.Equal(p[:5], []byte{10, 0x11, 0, 0, 0}) || !bytes.Equal(p[5:12], []byte{5, 0, 'A', 'l', 'p', 'h', 'a'}) || len(p) != 22 {
		t.Fatalf("0x3080 kind 10 % x", p)
	}
	if acc, ok := DecodeWarAnswer([]byte{1, 1}); !acc || !ok {
		t.Fatal("{1, 1} is an acceptance")
	}
	if acc, ok := DecodeWarAnswer([]byte{1, 0}); acc || !ok {
		t.Fatal("{1, 0} is a refusal")
	}
}

// Round 844: the wars kept -- begun once per pair, the points, the end
// crediting LodgedGold to the winner's booty, the booty taken, the members'
// counters -- on both stores.
func TestRound844WarsMem(t *testing.T) { testRound844Wars(t, NewMemStore()) }

func TestRound844WarsSQL(t *testing.T) { testRound844Wars(t, openTestSQLStore(t)) }

func testRound844Wars(t *testing.T, s warTestStore) {
	t.Helper()
	ctx := context.Background()
	a, err := s.Create(ctx, "Alpha", 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.Create(ctx, "Beta", 2, "Bram")
	if err != nil {
		t.Fatal(err)
	}
	c, err := s.Create(ctx, "Gamma", 3, "Cato")
	if err != nil {
		t.Fatal(err)
	}
	end := time.Now().Add(time.Hour).Truncate(time.Second)
	w, err := s.BeginWar(ctx, War{VictoryIndex: 1, LodgedGold: 200000, EndTime: end, GuildA: a.ID, GuildB: b.ID})
	if err != nil || w.ID == 0 || !w.EndTime.Equal(end) {
		t.Fatalf("BeginWar: %+v %v", w, err)
	}
	if _, err := s.BeginWar(ctx, War{GuildA: b.ID, GuildB: a.ID}); !errors.Is(err, ErrAlreadyAtWar) {
		t.Fatalf("a second war between them: %v", err)
	}
	w2, err := s.BeginWar(ctx, War{GuildA: c.ID, GuildB: a.ID})
	if err != nil || !w2.EndTime.IsZero() {
		t.Fatalf("an endless war: %+v %v", w2, err)
	}
	if ws, _ := s.WarsOf(ctx, a.ID); len(ws) != 2 || ws[0].ID != w.ID {
		t.Fatalf("Alpha's wars: %+v", ws)
	}
	if !AtWar(ctx, s, b.ID, a.ID) || AtWar(ctx, s, b.ID, c.ID) {
		t.Fatal("AtWar")
	}
	if got, err := s.AddWarPoints(ctx, w.ID, b.ID, 115); err != nil || got.PointsB != 115 || got.PointsA != 0 {
		t.Fatalf("points: %+v %v", got, err)
	}
	if _, err := s.AddWarPoints(ctx, w.ID, c.ID, 1); !errors.Is(err, ErrWarNotFound) {
		t.Fatalf("a third guild's points: %v", err)
	}
	if err := s.AddWarStats(ctx, 2, 1, 0, 115); err != nil {
		t.Fatal(err)
	}
	if err := s.AddWarStats(ctx, 1, 0, 1, 0); err != nil {
		t.Fatal(err)
	}
	if err := s.AddWarStats(ctx, 999, 1, 1, 1); err != nil {
		t.Fatalf("a character in no guild: %v", err)
	}
	gb, _ := s.Get(ctx, b.ID)
	ga, _ := s.Get(ctx, a.ID)
	if gb.Members[0].WarKill != 1 || gb.Members[0].Contribution != 115 || ga.Members[0].WarKilled != 1 {
		t.Fatalf("counters: %+v / %+v", gb.Members[0], ga.Members[0])
	}
	soon := time.Now().Add(5 * time.Second).Truncate(time.Second)
	if err := s.SetWarEnd(ctx, w.ID, soon); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.WarByID(ctx, w.ID); got == nil || !got.EndTime.Equal(soon) {
		t.Fatalf("the moved end: %+v", got)
	}
	ended, err := s.EndWar(ctx, w.ID, b.ID)
	if err != nil || ended.PointsB != 115 {
		t.Fatalf("EndWar: %+v %v", ended, err)
	}
	if _, err := s.EndWar(ctx, w.ID, b.ID); !errors.Is(err, ErrWarNotFound) {
		t.Fatalf("ending twice: %v", err)
	}
	if n, _ := s.Booty(ctx, b.ID); n != 200000 {
		t.Fatalf("Beta's booty %d", n)
	}
	if n, _ := s.Booty(ctx, a.ID); n != 0 {
		t.Fatalf("Alpha's booty %d", n)
	}
	if n, _ := s.TakeBooty(ctx, b.ID); n != 200000 {
		t.Fatalf("taken %d", n)
	}
	if n, _ := s.TakeBooty(ctx, b.ID); n != 0 {
		t.Fatalf("taken twice %d", n)
	}
	if ws, _ := s.Wars(ctx); len(ws) != 1 || ws[0].ID != w2.ID {
		t.Fatalf("the wars left: %+v", ws)
	}
}
