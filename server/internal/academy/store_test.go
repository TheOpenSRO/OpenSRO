package academy

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/testdb"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// TestMain holds the shared test-database lock for the package run.
func TestMain(m *testing.M) {
	release := testdb.Lock(testDSN())
	code := m.Run()
	release()
	os.Exit(code)
}

func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

// eachStore runs f against a fresh MemStore and a fresh SQLStore.
func eachStore(t *testing.T, f func(t *testing.T, s Store)) {
	t.Run("mem", func(t *testing.T) { f(t, NewMemStore()) })
	t.Run("sql", func(t *testing.T) {
		db, err := sql.Open("pgx", testDSN())
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		t.Cleanup(func() { db.Close() })
		if err := db.Ping(); err != nil {
			t.Fatalf("postgres: %v (is it running?)", err)
		}
		s, err := NewSQLStore(db)
		if err != nil {
			t.Fatalf("NewSQLStore: %v", err)
		}
		if err := s.TruncateForTest(context.Background()); err != nil {
			t.Fatalf("truncate: %v", err)
		}
		f(t, s)
	})
}

var t0 = time.Date(2026, 1, 1, 0, 0, 2, 0, time.Local)

func joiner(id int64, level int) Joiner {
	return Joiner{CharID: id, RefObjID: 1907, Name: "char" + string(rune('A'+id%26)), CurLevel: level, MaxLevel: level}
}

func found(t *testing.T, s Store) *Camp {
	t.Helper()
	c, err := s.Found(context.Background(), joiner(1, 70), t0)
	if err != nil {
		t.Fatalf("Found: %v", err)
	}
	return c
}

func TestStoreFound(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		c := found(t, s)
		want := time.Date(2026, 1, 1, 0, 0, 0, 0, time.Local)
		if !c.CreationDate.Equal(want) || !c.LatestEvaluationDate.Equal(want) {
			t.Errorf("dates %v / %v, want %v (minute-rounded)", c.CreationDate, c.LatestEvaluationDate, want)
		}
		if c.Rank != RankNone || c.GraduateCount != 0 || c.EvaluationPoint != 0 || c.NoticeTitle != "" || c.Notice != "" {
			t.Errorf("camp %+v, want rank 5, no graduates, no points, no notice", c)
		}
		if len(c.Members) != 1 || c.Members[0].Class != MemberClassGuardian || c.Members[0].JoinedLevel != 70 {
			t.Fatalf("members %+v, want the founder as guardian joined at 70", c.Members)
		}
		rows, _ := s.BuffRows(context.Background(), 1)
		if len(rows) != 6 || rows[0].Type != 0 || rows[0].Slot != 0 || rows[5].Type != 3 || rows[5].Slot != 5 ||
			!rows[1].Start.Equal(BuffStartNone) {
			t.Errorf("guardian buff rows %+v, want type 0 slot 0 + type 3 slots 1..5 idle", rows)
		}
		if _, err := s.Found(context.Background(), joiner(1, 70), t0); !errors.Is(err, ErrInCamp) {
			t.Errorf("second founding: %v, want ErrInCamp", err)
		}
	})
}

func TestStoreAddMemberRules(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		c := found(t, s)
		joined := time.Date(2026, 1, 1, 0, 16, 41, 0, time.Local)
		c, err := s.AddMember(ctx, c.ID, joiner(2, 1), joined)
		if err != nil {
			t.Fatal(err)
		}
		m, _ := c.Member(2)
		if m.Class != MemberClassStudent || !m.JoinDate.Equal(time.Date(2026, 1, 1, 0, 17, 0, 0, time.Local)) {
			t.Errorf("apprentice %+v, want class 2 joined 00:17:00", m)
		}
		rows, _ := s.BuffRows(ctx, 2)
		if len(rows) != 2 || rows[0].Type != 0 || rows[1].Type != 3 || rows[1].Slot != 1 {
			t.Errorf("apprentice buff rows %+v", rows)
		}
		// Class from the max level: an assistant at 40.
		c, err = s.AddMember(ctx, c.ID, joiner(3, 40), joined)
		if err != nil {
			t.Fatal(err)
		}
		if m, _ := c.Member(3); m.Class != MemberClassSecondGuardian {
			t.Errorf("level 40 class %d, want 1", m.Class)
		}
		if rows, _ := s.BuffRows(ctx, 3); len(rows) != 0 {
			t.Errorf("assistant buff rows %+v, want none", rows)
		}
		// Order: guardian first, then join order.
		if c.Members[0].CharID != 1 || c.Members[1].CharID != 2 || c.Members[2].CharID != 3 {
			t.Errorf("order %v", c.Members)
		}
		// In a camp already.
		if _, err := s.AddMember(ctx, c.ID, joiner(2, 1), joined); !errors.Is(err, ErrInCamp) {
			t.Errorf("rejoin: %v", err)
		}
		// A second guardian.
		if _, err := s.AddMember(ctx, c.ID, joiner(9, 60), joined); !errors.Is(err, ErrGuardianExists) {
			t.Errorf("second guardian: %v", err)
		}
		// A third assistant.
		if _, err := s.AddMember(ctx, c.ID, joiner(4, 45), joined); err != nil {
			t.Fatal(err)
		}
		if _, err := s.AddMember(ctx, c.ID, joiner(5, 50), joined); !errors.Is(err, ErrAssistantsFull) {
			t.Errorf("third assistant: %v", err)
		}
		// A sixth apprentice.
		for id := int64(10); id < 14; id++ {
			if _, err := s.AddMember(ctx, c.ID, joiner(id, 10), joined); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := s.AddMember(ctx, c.ID, joiner(20, 10), joined); !errors.Is(err, ErrApprenticeFull) {
			t.Errorf("sixth apprentice: %v", err)
		}
		if _, err := s.AddMember(ctx, 999, joiner(21, 10), joined); !errors.Is(err, ErrNoSuchCamp) {
			t.Errorf("no camp: %v", err)
		}
	})
}

func TestStoreRemoveBanksAssistants(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		c := found(t, s)
		s.AddMember(ctx, c.ID, joiner(2, 45), t0)
		s.AddMember(ctx, c.ID, joiner(3, 50), t0)
		s.AddMember(ctx, c.ID, joiner(4, 5), t0)
		// Give both assistants points through an apprentice graduation
		// paid at join level 5: the guardian +35, each assistant +3.
		s.AddMember(ctx, c.ID, joiner(5, 5), t0)
		if _, _, err := s.Graduate(ctx, 5, 1, t0); err != nil {
			t.Fatal(err)
		}
		// Leaving: 3 points less 10, floored at 0.
		if _, m, err := s.RemoveMember(ctx, 2, RemoveLeft); err != nil || m.CharID != 2 {
			t.Fatalf("leave: %v %+v", err, m)
		}
		if n, _ := s.Bank(ctx, 2); n != 0 {
			t.Errorf("left assistant banked %d, want 0 (3 - 10 floored)", n)
		}
		// Banned: all 3.
		if _, _, err := s.RemoveMember(ctx, 3, RemoveBanned); err != nil {
			t.Fatal(err)
		}
		if n, _ := s.Bank(ctx, 3); n != 3 {
			t.Errorf("banned assistant banked %d, want 3", n)
		}
		// An apprentice's buff rows go.
		if _, _, err := s.RemoveMember(ctx, 4, RemoveLeft); err != nil {
			t.Fatal(err)
		}
		if rows, _ := s.BuffRows(ctx, 4); len(rows) != 0 {
			t.Errorf("apprentice rows after leaving %+v", rows)
		}
		// Never the guardian.
		if _, _, err := s.RemoveMember(ctx, 1, RemoveBanned); !errors.Is(err, ErrGuardian) {
			t.Errorf("guardian removal: %v", err)
		}
		if _, _, err := s.RemoveMember(ctx, 77, RemoveLeft); !errors.Is(err, ErrNotInCamp) {
			t.Errorf("non-member: %v", err)
		}
		// The bank comes back with the next membership.
		c, err := s.AddMember(ctx, c.ID, joiner(3, 50), t0)
		if err != nil {
			t.Fatal(err)
		}
		if m, _ := c.Member(3); m.Honor != 3 {
			t.Errorf("rejoined honor %d, want the banked 3", m.Honor)
		}
		if n, _ := s.Bank(ctx, 3); n != 0 {
			t.Errorf("bank after rejoining %d, want the row removed", n)
		}
	})
}

func TestStoreGraduationRules(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		c := found(t, s)
		s.AddMember(ctx, c.ID, joiner(2, 45), t0)
		s.AddMember(ctx, c.ID, joiner(3, 41), t0)
		s.AddMember(ctx, c.ID, joiner(4, 10), t0) // pays: 30 / 3
		s.AddMember(ctx, c.ID, joiner(5, 31), t0) // joined above 30: no pay
		later := t0.Add(48 * time.Hour)
		c, g, err := s.Graduate(ctx, 4, 5, later)
		if err != nil {
			t.Fatal(err)
		}
		if c.GraduateCount != 1 || c.EvaluationPoint != 5 || !c.LatestEvaluationDate.Equal(Minute(later)) {
			t.Errorf("camp after a paying graduation %+v", c)
		}
		if len(g.Shares) != 3 || g.Shares[0] != (HonorShare{1, 30}) || g.Shares[1] != (HonorShare{2, 3}) || g.Shares[2] != (HonorShare{3, 3}) {
			t.Errorf("shares %+v, want guardian 30, assistants 3 each", g.Shares)
		}
		if _, in := c.Member(4); in {
			t.Error("the graduate is still a member")
		}
		if rows, _ := s.BuffRows(ctx, 4); len(rows) != 0 {
			t.Errorf("graduate's rows %+v", rows)
		}
		c, g, err = s.Graduate(ctx, 5, 5, later.Add(time.Hour))
		if err != nil {
			t.Fatal(err)
		}
		if c.GraduateCount != 2 || c.EvaluationPoint != 5 || !c.LatestEvaluationDate.Equal(Minute(later)) || len(g.Shares) != 0 {
			t.Errorf("camp after a non-paying graduation %+v shares %+v", c, g.Shares)
		}
		// An assistant's graduation banks its points and counts nothing.
		c, _, err = s.Graduate(ctx, 2, 0, later)
		if err != nil {
			t.Fatal(err)
		}
		if c.GraduateCount != 2 {
			t.Errorf("assistant graduation counted: %d", c.GraduateCount)
		}
		if n, _ := s.Bank(ctx, 2); n != 3 {
			t.Errorf("graduated assistant banked %d, want 3", n)
		}
		if _, _, err := s.Graduate(ctx, 1, 0, later); !errors.Is(err, ErrGuardian) {
			t.Errorf("guardian graduation: %v", err)
		}
	})
}

func TestStoreDisband(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		c := found(t, s)
		s.AddMember(ctx, c.ID, joiner(2, 45), t0)
		s.AddMember(ctx, c.ID, joiner(3, 5), t0)
		s.Graduate(ctx, 3, 1, t0) // guardian +35, assistant +3
		members, err := s.Disband(ctx, c.ID)
		if err != nil || len(members) != 2 {
			t.Fatalf("disband: %v %+v", err, members)
		}
		if n, _ := s.Bank(ctx, 2); n != 3 {
			t.Errorf("assistant banked %d at disband, want 3", n)
		}
		if n, _ := s.Bank(ctx, 1); n != 0 {
			t.Errorf("guardian banked %d at disband, want 0 (reset)", n)
		}
		if _, err := s.CampOf(ctx, 1); !errors.Is(err, ErrNotInCamp) {
			t.Errorf("guardian still in a camp: %v", err)
		}
		if _, err := s.Get(ctx, c.ID); !errors.Is(err, ErrNoSuchCamp) {
			t.Errorf("camp still there: %v", err)
		}
		if rows, _ := s.BuffRows(ctx, 1); len(rows) != 0 {
			t.Errorf("guardian rows after disband %+v", rows)
		}
	})
}

func TestStoreNoticeLevelsNameBody(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		c := found(t, s)
		if err := s.SetNotice(ctx, c.ID, "Hello Academy", "Test notice line"); err != nil {
			t.Fatal(err)
		}
		if err := s.SetLevels(ctx, 1, 71, 71); err != nil {
			t.Fatal(err)
		}
		if err := s.SetName(ctx, 1, "Renamed"); err != nil {
			t.Fatal(err)
		}
		if err := s.SetRefObj(ctx, 1, 1908); err != nil {
			t.Fatal(err)
		}
		c, _ = s.CampOf(ctx, 1)
		m := c.Members[0]
		if c.NoticeTitle != "Hello Academy" || c.Notice != "Test notice line" || m.CurLevel != 71 || m.MaxLevel != 71 ||
			m.JoinedLevel != 70 || m.Name != "Renamed" || m.RefObjID != 1908 {
			t.Errorf("after updates %+v / %+v", c, m)
		}
		if err := s.SetLevels(ctx, 99, 1, 1); !errors.Is(err, ErrNotInCamp) {
			t.Errorf("non-member levels: %v", err)
		}
	})
}

func TestStoreSpendHonor(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		c := found(t, s)
		s.AddMember(ctx, c.ID, joiner(3, 5), t0)
		s.Graduate(ctx, 3, 1, t0) // guardian 35
		if _, err := s.SpendHonor(ctx, 1, 36, nil); !errors.Is(err, ErrHonorShort) {
			t.Errorf("over-spend: %v", err)
		}
		boom := errors.New("pay failed")
		if _, err := s.SpendHonor(ctx, 1, 10, func() error { return boom }); !errors.Is(err, boom) {
			t.Errorf("failed pay: %v", err)
		}
		left, err := s.SpendHonor(ctx, 1, 10, func() error { return nil })
		if err != nil || left != 25 {
			t.Errorf("spend: %d %v, want 25", left, err)
		}
		if _, err := s.SpendHonor(ctx, 99, 1, nil); !errors.Is(err, ErrNotInCamp) {
			t.Errorf("non-member: %v", err)
		}
	})
}

func TestStoreRankUpdate(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		c := found(t, s)
		// Ten paying graduations at points 1 make EvaluationPoint 10.
		for id := int64(100); id < 110; id++ {
			s.AddMember(ctx, c.ID, joiner(id, 1), t0)
			if _, _, err := s.Graduate(ctx, id, 1, t0); err != nil {
				t.Fatal(err)
			}
		}
		other, _ := s.Found(ctx, joiner(2, 60), t0)
		changes, err := s.UpdateRanks(ctx, t0)
		if err != nil {
			t.Fatal(err)
		}
		if len(changes) != 1 || changes[0] != (RankChange{CampID: c.ID, Rank: 1}) {
			t.Errorf("changes %+v, want the eligible camp to rank 1", changes)
		}
		rows, _ := s.Ranking(ctx)
		if len(rows) != 1 || rows[0] != (RankRow{Ranking: 1, CampID: c.ID, Rank: 1}) {
			t.Errorf("rows %+v", rows)
		}
		if got, _ := s.Get(ctx, other.ID); got.Rank != RankNone {
			t.Errorf("ineligible rank %d", got.Rank)
		}
		if last, _ := s.LastRankUpdate(ctx); !last.Equal(t0) {
			t.Errorf("last update %v", last)
		}
		// Unchanged on a second run.
		if changes, _ := s.UpdateRanks(ctx, t0); len(changes) != 0 {
			t.Errorf("second run changes %+v", changes)
		}
	})
}

func TestRankCampsBands(t *testing.T) {
	var camps []*Camp
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.Local)
	for i := 1; i <= 60; i++ {
		// Points 10..69; camp 60 has the most. Two camps share 30 points
		// and are ordered by their LatestEvaluationDate.
		camps = append(camps, &Camp{ID: int64(i), EvaluationPoint: 9 + i, LatestEvaluationDate: base.Add(time.Duration(i) * time.Hour)})
	}
	camps = append(camps, &Camp{ID: 61, EvaluationPoint: 9}) // below 10
	camps[40].EvaluationPoint = camps[39].EvaluationPoint    // ids 40 and 41 tie
	camps[40].LatestEvaluationDate = base                    // id 41 is older
	rows, ranks := RankCamps(camps)
	if len(rows) != RankedCamps {
		t.Fatalf("%d rows, want %d", len(rows), RankedCamps)
	}
	if rows[0].CampID != 60 || rows[0].Rank != 1 || rows[4].Rank != 1 || rows[5].Rank != 2 || rows[14].Rank != 2 ||
		rows[15].Rank != 3 || rows[29].Rank != 3 || rows[30].Rank != 4 || rows[49].Rank != 4 {
		t.Errorf("bands wrong: %+v", rows)
	}
	var i40, i41 int
	for i, r := range rows {
		switch r.CampID {
		case 40:
			i40 = i
		case 41:
			i41 = i
		}
	}
	if i41 > i40 {
		t.Errorf("tie: camp 41 (older date) at %d after camp 40 at %d", i41, i40)
	}
	if ranks[61] != RankNone || ranks[1] != RankNone {
		t.Errorf("camps 61 (9 points) and 1 (51st) rank %d / %d, want 5", ranks[61], ranks[1])
	}
}

func TestRankUpdateSchedule(t *testing.T) {
	now := time.Date(2026, 1, 2, 12, 0, 0, 0, time.Local)
	if !RankUpdateDue(time.Time{}, now) {
		t.Error("never run must be due")
	}
	if RankUpdateDue(time.Date(2026, 1, 2, 0, 0, 30, 0, time.Local), now) {
		t.Error("run today must not be due")
	}
	if !RankUpdateDue(time.Date(2026, 1, 1, 23, 59, 0, 0, time.Local), now) {
		t.Error("run yesterday must be due")
	}
	if got := NextRankUpdate(now); !got.Equal(time.Date(2026, 1, 3, 0, 0, 0, 0, time.Local)) {
		t.Errorf("next %v", got)
	}
}
