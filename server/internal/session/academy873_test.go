package session

import (
	"context"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/academy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 873: the academy guardian's honor buffs (SKILL_TC_*) once each on
// its own client's buff board in every path -- the world entry, a teleport,
// a move into another world (an instance) and out, a death and the revive at
// the return point, a rank change and the disband while its arrival holds it
// (world.Entity.Held), and the revive in place.

// honorSink records what is sent to the guardian's session, in order.
type honorSink struct {
	mu sync.Mutex
	ps []*proto.Packet
}

func (s *honorSink) SendRemote(ps []*proto.Packet) error {
	s.mu.Lock()
	s.ps = append(s.ps, ps...)
	s.mu.Unlock()
	return nil
}

func (s *honorSink) CloseRemote() error { return nil }

// board is the client's buff board for owner as these packets leave it: an
// OpBuffStart adds its token (a token already held is replaced, a re-send:
// buff_roster.gd), an OpBuffEnd removes its tokens. It answers token -> skill.
func (s *honorSink) board(t *testing.T, owner int64) map[uint32]int64 {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	b := map[uint32]int64{}
	for _, p := range s.ps {
		switch p.Opcode {
		case OpBuffStart:
			m, err := DecodeBuffStart(p.Data)
			if err != nil {
				t.Fatal(err)
			}
			if m.OwnerID == owner {
				b[m.Token] = m.SkillID
			}
		case OpBuffEnd:
			m, err := DecodeBuffEnd(p.Data)
			if err != nil {
				t.Fatal(err)
			}
			if m.OwnerID == owner {
				for _, tok := range m.Tokens {
					delete(b, tok)
				}
			}
		}
	}
	return b
}

// rankedStore is an academy store whose camps stand at a rank the test sets
// (the daily update's result).
type rankedStore struct {
	*academy.MemStore
	mu   sync.Mutex
	rank int
}

func (s *rankedStore) setRank(r int) { s.mu.Lock(); s.rank = r; s.mu.Unlock() }

func (s *rankedStore) ranked(c *academy.Camp, err error) (*academy.Camp, error) {
	if c != nil {
		s.mu.Lock()
		c.Rank = s.rank
		s.mu.Unlock()
	}
	return c, err
}

func (s *rankedStore) CampOf(ctx context.Context, charID int64) (*academy.Camp, error) {
	return s.ranked(s.MemStore.CampOf(ctx, charID))
}

// UpdateRanks is the daily update moving every camp to the set rank.
func (s *rankedStore) UpdateRanks(ctx context.Context, now time.Time) ([]academy.RankChange, error) {
	var out []academy.RankChange
	for id := int64(1); ; id++ {
		c, err := s.Get(ctx, id)
		if err != nil || c == nil {
			break
		}
		out = append(out, academy.RankChange{CampID: id, Rank: c.Rank})
	}
	return out, nil
}

func (s *rankedStore) Get(ctx context.Context, campID int64) (*academy.Camp, error) {
	return s.ranked(s.MemStore.Get(ctx, campID))
}

// honorSkills is the four SKILL_TC_* rows, untimed, each its own group.
type honorSkills map[string]*refdata.Skill

func (h honorSkills) GetSkillByCode(_ context.Context, code string) (*refdata.Skill, error) {
	return h[code], nil
}

// honorSkillIDs is the rows' ids by rank: crown, gold, silver, copper.
var honorSkillIDs = map[string]int64{"SKILL_TC_CROWN_BUFF_01": 873000, "SKILL_TC_GOLD_BUFF_01": 873001,
	"SKILL_TC_SILVER_BUFF_01": 873002, "SKILL_TC_COPPER_BUFF_01": 873003}

type honorRig struct {
	hub   *world.Hub
	store *rankedStore
	sink  *honorSink
	sess  *gateway.Session
	id    int64
	rt    *academyRuntime
}

func startHonor873(t *testing.T, id int64) *honorRig {
	t.Helper()
	ctx := context.Background()
	skills := honorSkills{}
	for code, sid := range honorSkillIDs {
		skills[code] = &refdata.Skill{ID: sid, BasicCode: code, GroupID: sid, BasicLevel: 1}
	}
	r := &honorRig{hub: world.NewHub(), store: &rankedStore{MemStore: academy.NewMemStore(), rank: 1},
		sink: &honorSink{}, id: id}
	if _, err := r.store.Found(ctx, academy.Joiner{CharID: id, Name: "Aria", CurLevel: 70, MaxLevel: 70}, time.Now()); err != nil {
		t.Fatal(err)
	}
	SetAcademy(AcademyDeps{Store: r.store, Hub: r.hub, Skills: skills})
	t.Cleanup(func() { SetAcademy(AcademyDeps{}) })
	r.rt = academyRT.Load()
	r.sess = gateway.NewRemoteSession(uint64(id), r.sink, nil)
	t.Cleanup(func() {
		buffBooks.EndWhere(id, func(buff.Record) bool { return true })
	})
	return r
}

// enter is the world entry: in the hub held, then the client's 0x3012
// (Release) and the arrival's academy part (academyArrived, vslot_391).
func (r *honorRig) enter(t *testing.T) {
	t.Helper()
	r.hub.EnterHeld(r.sess, r.id, "Aria", 70, "jangan", world.Position{X: 1000, Z: 1000})
	sendOwnBuffs(r.entity(t), time.Now())
	r.arrive(t)
}

func (r *honorRig) entity(t *testing.T) world.Entity {
	t.Helper()
	e, ok := hubOfChar(r.hub, r.id).EntityByCharacterID(r.id)
	if !ok {
		t.Fatal("the guardian is not in the world")
	}
	return e
}

// teleport is a zone change held (warpTo): the move, then the zone change's
// own buff list (sendOwnBuffs).
func (r *honorRig) teleport(t *testing.T, to *world.Hub, x float64) {
	t.Helper()
	h := hubOfChar(r.hub, r.id)
	if _, _, _, ok := h.Transfer(r.sess, to, "jangan", world.Position{X: x, Z: 1000}, true); !ok {
		t.Fatal("the move failed")
	}
	if !r.entity(t).Held {
		t.Fatal("the move did not hold the guardian")
	}
	sendOwnBuffs(r.entity(t), time.Now())
}

// arrive is the client's 0x3012: Release, then academyArrived.
func (r *honorRig) arrive(t *testing.T) {
	t.Helper()
	if _, _, ok := hubOfChar(r.hub, r.id).Release(r.sess); !ok {
		t.Fatal("the release failed")
	}
	academyArrived(context.Background(), r.entity(t))
}

// check is the board against the book: each of want's skills exactly once
// on the board, the board's tokens the book's, no other honor buff.
func (r *honorRig) check(t *testing.T, step string, rank int) {
	t.Helper()
	board := r.sink.board(t, r.id)
	count := map[int64]int{}
	for _, sid := range board {
		count[sid]++
	}
	want := map[int64]bool{}
	for _, code := range HonorBuffsFor(rank) {
		want[honorSkillIDs[code]] = true
	}
	for _, sid := range honorSkillIDs {
		n := count[sid]
		if want[sid] && n != 1 || !want[sid] && n != 0 {
			t.Errorf("%s: skill %d is on the board %d times, want %v (board %v)", step, sid, n, want[sid], board)
		}
	}
	var bookTok, boardTok []uint32
	for _, rec := range buffBooks.Active(r.id) {
		bookTok = append(bookTok, rec.Token)
	}
	for tok := range board {
		boardTok = append(boardTok, tok)
	}
	sort.Slice(bookTok, func(i, j int) bool { return bookTok[i] < bookTok[j] })
	sort.Slice(boardTok, func(i, j int) bool { return boardTok[i] < boardTok[j] })
	if len(bookTok) != len(boardTok) {
		t.Fatalf("%s: the book holds tokens %v, the board %v", step, bookTok, boardTok)
	}
	for i := range bookTok {
		if bookTok[i] != boardTok[i] {
			t.Fatalf("%s: the book holds tokens %v, the board %v", step, bookTok, boardTok)
		}
	}
}

// die is the death's end of every buff (OpenSRO's book at a death).
func (r *honorRig) die(t *testing.T) {
	t.Helper()
	ended, sp := buffBooks.EndWhere(r.id, func(buff.Record) bool { return true })
	broadcastBuffEnd(zoneOf(r.hub, r.id), r.id, ended, sp)
}

func TestHonorBuffs873OncePerPath(t *testing.T) {
	r := startHonor873(t, 8730001)
	r.enter(t)
	r.check(t, "world entry", 1)

	r.teleport(t, r.hub, 1200)
	r.arrive(t)
	r.check(t, "teleport", 1)

	inst := world.NewHub()
	r.teleport(t, inst, 500)
	r.arrive(t)
	r.check(t, "into another world", 1)

	// The player's log: a death there, the return point (the move, then the
	// revive while held), the client's 0x3012.
	r.die(t)
	r.check(t, "death", 5)
	r.teleport(t, r.hub, 1000)
	academyRevived(context.Background(), r.id)
	r.arrive(t)
	r.check(t, "revive at the return point", 1)

	// A second return point with the buffs on (the player's second revive).
	r.teleport(t, r.hub, 1000)
	academyRevived(context.Background(), r.id)
	r.arrive(t)
	r.check(t, "return point with the buffs on", 1)

	// A revive in place (not held): re-engaged at once.
	r.die(t)
	academyRevived(context.Background(), r.id)
	r.check(t, "revive in place", 1)
}

func TestHonorBuffs873WhileHeld(t *testing.T) {
	r := startHonor873(t, 8730002)
	r.enter(t)
	r.check(t, "world entry", 1)

	// The daily update moves the rank while the guardian is loading.
	r.teleport(t, r.hub, 1200)
	r.store.setRank(2)
	r.rt.engageHonorBuffs(context.Background(), r.id, 2)
	r.check(t, "rank change while held", 2)
	r.arrive(t)
	r.check(t, "rank change, arrived", 2)

	// The daily update while it plays in another world.
	inst := world.NewHub()
	r.teleport(t, inst, 500)
	r.arrive(t)
	r.store.setRank(3)
	r.rt.updateRanks(context.Background(), time.Now())
	r.check(t, "rank update in another world", 3)

	// The disband while held: every icon goes.
	r.teleport(t, r.hub, 1000)
	r.rt.cancelHonorBuffs(r.id)
	r.check(t, "disband while held", 5)
}
