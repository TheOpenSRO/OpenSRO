package session

// Round 785's server review: the quest runtime's findings 1, 2, 8 and 14,
// each pinned by a test that failed before its fix.

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"sync/atomic"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// reviewHookInv is a bag whose AddItem runs a hook first (the window
// between a kill's credit and its drop).
type reviewHookInv struct {
	inventory.Store
	add func(ctx context.Context, c, id int64, n int) error
}

func (h reviewHookInv) AddItem(ctx context.Context, c, id int64, n int) error { return h.add(ctx, c, id, n) }

func reviewMixCatalog() *quest.Catalog {
	q := &quest.Quest{ID: 911, Code: "QT_MIX", Level: 1, Source: quest.SourceScript, Race: -1,
		StartNPCs: []string{"N"}, CompleteNPCs: []string{"N"},
		Missions: []quest.Mission{
			{Index: 0, Type: quest.MissionGatherFromMonster, Targets: []string{"MOB_T"}, Rates: []float64{100}, Count: 1, Item: "ITEM_T_PELT", MonsterClass: -1},
			{Index: 1, Type: quest.MissionKillMonster, Targets: []string{"MOB_T"}, Count: 1, MonsterClass: -1},
		}}
	return quest.NewCatalog([]*quest.Quest{q})
}

func reviewPeltRef(ctx context.Context) *refdata.MemStore {
	ref := refdata.NewMemStore()
	ref.ImportItems(ctx, []refdata.Item{{ID: 7001, CodeName: "ITEM_T_PELT", MaxStack: 50}})
	return ref
}

// Finding 2: a full bag refuses the gather drop while the same kill finishes
// the kill mission. The quest stayed AchievedButNotPaid with the gather at
// 0/1 (the rollback lowered the count but not the status). Now the refused
// drop counts nothing and the quest stays open.
func TestReview785FullBagDoesNotFinishTheQuest(t *testing.T) {
	ctx := context.Background()
	ref := reviewPeltRef(ctx)
	store := quest.NewMemStore()
	store.Put(ctx, 1, quest.State{QuestID: 911, Status: quest.StatusAchieving, Counts: []int{0, 0}})
	inv := reviewHookInv{Store: inventory.NewMemStore(ref), add: func(context.Context, int64, int64, int) error { return errors.New("bag full") }}
	InstallQuests(reviewMixCatalog(), QuestDeps{Store: store, Inv: inv, Items: ref})
	defer InstallQuests(nil, QuestDeps{})
	questOnKill(ctx, nil, 1, combat.Monster{ID: 5, CodeName: "MOB_T"})
	ql, _ := questRT.Load().logOf(ctx, 1)
	s := ql.snapshot(911)
	if s.Status != quest.StatusAchieving || len(s.Counts) != 2 || s.Counts[0] != 0 || s.Counts[1] != 1 {
		t.Fatalf("after a kill with a full bag: status %d counts %v; want achieving, gather 0/1, kill 1/1", s.Status, s.Counts)
	}
	st, _ := store.States(ctx, 1)
	if len(st) != 1 || st[0].Status != quest.StatusAchieving {
		t.Fatalf("stored %+v; want the quest still open", st)
	}
}

// Finding 1: a give-up between the kill's credit and the refused drop. The
// rollback indexed the abandoned state's nil Counts and panicked (with
// ql.mu held on a packet goroutine). Now nothing is indexed; the quest
// stays given up.
func TestReview785AbandonBetweenCreditAndDrop(t *testing.T) {
	ctx := context.Background()
	ref := reviewPeltRef(ctx)
	store := quest.NewMemStore()
	store.Put(ctx, 1, quest.State{QuestID: 911, Status: quest.StatusAchieving, Counts: []int{0, 0}, Achieved: 1})
	cat := reviewMixCatalog()
	var rtq *questRuntime
	inv := reviewHookInv{Store: inventory.NewMemStore(ref), add: func(context.Context, int64, int64, int) error {
		ql, _ := rtq.logOf(ctx, 1)
		ql.mu.Lock()
		quest.Abandon(ql.log, cat.ByID[911])
		ql.mu.Unlock()
		return errors.New("bag full")
	}}
	InstallQuests(cat, QuestDeps{Store: store, Inv: inv, Items: ref})
	defer InstallQuests(nil, QuestDeps{})
	rtq = questRT.Load()
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("questOnKill panicked: %v", r)
			}
		}()
		questOnKill(ctx, nil, 1, combat.Monster{ID: 5, CodeName: "MOB_T"})
	}()
	ql, _ := rtq.logOf(ctx, 1)
	// The lock is free (a panic under it left it held).
	if !ql.mu.TryLock() {
		t.Fatal("ql.mu left locked")
	}
	ql.mu.Unlock()
	s := ql.snapshot(911)
	if s.Status != quest.StatusAchieved || s.Counts != nil {
		t.Fatalf("after the give-up: %+v; want the paid-before state with no counts (no -1, no reopen)", s)
	}
}

// Finding 1, the drop given after the give-up: the kill's drop goes back
// and the store is not handed a state for a quest no longer in the log.
func TestReview785DropAfterAbandonIsTakenBack(t *testing.T) {
	ctx := context.Background()
	ref := reviewPeltRef(ctx)
	store := quest.NewMemStore()
	store.Put(ctx, 1, quest.State{QuestID: 911, Status: quest.StatusAchieving, Counts: []int{0, 0}})
	cat := reviewMixCatalog()
	bag := inventory.NewMemStore(ref)
	var rtq *questRuntime
	inv := reviewHookInv{Store: bag, add: func(ctx context.Context, c, id int64, n int) error {
		ql, _ := rtq.logOf(ctx, 1)
		ql.mu.Lock()
		quest.Abandon(ql.log, cat.ByID[911])
		ql.mu.Unlock()
		return bag.AddItem(ctx, c, id, n)
	}}
	InstallQuests(cat, QuestDeps{Store: store, Inv: inv, Items: ref})
	defer InstallQuests(nil, QuestDeps{})
	rtq = questRT.Load()
	questOnKill(ctx, nil, 1, combat.Monster{ID: 5, CodeName: "MOB_T"})
	if slots, _ := bag.List(ctx, 1); len(slots) != 0 {
		t.Fatalf("the bag holds %+v; want the drop of a given-up quest taken back", slots)
	}
	st, _ := store.States(ctx, 1)
	for _, s := range st {
		if s.QuestID == 911 && s.Status != quest.StatusAchieving {
			t.Fatalf("stored %+v; want no state written for the given-up quest", s)
		}
	}
}

// reviewFailStore fails the write of a paid state while fail is set.
type reviewFailStore struct {
	quest.Store
	fail atomic.Bool
}

func (s *reviewFailStore) Put(ctx context.Context, c int64, st quest.State) error {
	if s.fail.Load() && st.Status == quest.StatusAchieved {
		return errors.New("database down")
	}
	return s.Store.Put(ctx, c, st)
}

// reviewQuestWorld is TestQuestTalkKillRewardFlow's world: Aria logged in
// beside NPC_T_GIVER (uid giver.UID, at x 100 in jangan).
type reviewQuestWorld struct {
	cl    *chatClient
	giver npcspawn.Record
	id    int64
	chars *character.MemStore
	inv   inventory.Store
	hub   *world.Hub
	ctx   context.Context
}

func startReviewQuestWorld(t *testing.T, store quest.Store) *reviewQuestWorld {
	t.Helper()
	return startQuestWorld(t, store, testQuestCatalog(), nil)
}

// startQuestWorld is startReviewQuestWorld with its catalogue and party hub
// (round 819).
func startQuestWorld(t *testing.T, store quest.Store, cat *quest.Catalog, parties *party.Hub) *reviewQuestWorld {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	accounts.Add("Aria", "pw")
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	ref := refdata.NewMemStore()
	ref.ImportItems(ctx, []refdata.Item{{ID: 7001, CodeName: "ITEM_T_PELT", MaxStack: 50}, {ID: 7002, CodeName: "ITEM_T_PRIZE", MaxStack: 1}})
	inv := inventory.NewMemStore(ref)
	hub := world.NewHub()
	giver := npcAt(7, 100, 0, npcspawn.FromNest)
	giver.Code = "NPC_T_GIVER"
	giver.Flags, giver.Interact = npcspawn.FlagInteractions, []byte{1}
	installNPCsForTest(t, giver)
	InstallQuests(cat, QuestDeps{Store: store, Chars: chars, Inv: inv, Items: ref, Hub: hub, Parties: parties})
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub), NPCTalkHandler(hub, trade.NewHub()), QuestHandler())
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle}
	sctx, cancel := context.WithCancel(context.Background())
	go srv.ListenAndServe(sctx)
	conn := dialTestServer(t, srv.Addr)
	cl := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
	t.Cleanup(func() {
		conn.Close()
		cancel()
		InstallQuests(nil, QuestDeps{})
	})
	cl.send(OpLogin, (&LoginRequest{Username: "Aria", Password: "pw"}).Encode())
	cl.next(OpLoginResult)
	cl.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	cl.next(OpEnterWorldResult)
	cl.next(quest.OpLog)
	e, _ := hub.FindByName("Aria")
	if e.Zone != "jangan" {
		t.Skipf("the test NPC stands in the jangan frame; the world put Aria in %q", e.Zone)
	}
	sid := e.Session.ID()
	ForgetNPCInteraction(sid)
	t.Cleanup(func() { ForgetNPCInteraction(sid); ForgetQuestSession(sid) })
	hub.Relocate(e.Session, world.Position{X: 50, Z: 0}, world.MoveRelocate, 0)
	return &reviewQuestWorld{cl: cl, giver: giver.Record, id: c.ID, chars: chars, inv: inv, hub: hub, ctx: ctx}
}

func (w *reviewQuestWorld) moveTo(x, z float64) {
	e, _ := w.hub.FindByName("Aria")
	w.hub.Relocate(e.Session, world.Position{X: x, Z: z}, world.MoveRelocate, 0)
}

// openTalk selects the giver and opens its talk: the list page.
func (w *reviewQuestWorld) openTalk(t *testing.T) []byte {
	t.Helper()
	w.cl.send(npctalk.OpSelect, npctalk.EncodeEntity(w.giver.UID))
	w.cl.next(npctalk.OpSelectResult)
	w.cl.send(npctalk.OpOpen, npctalk.EncodeOpen(w.giver.UID, npctalk.IDTalk))
	w.cl.next(npctalk.OpOpenResult)
	return w.cl.next(quest.OpTalkPage).Data
}

// accept takes QT_HUNT (the list's first line) at the giver.
func (w *reviewQuestWorld) accept(t *testing.T) {
	t.Helper()
	w.openTalk(t)
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	w.cl.next(quest.OpTalkPage)
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespAccept})
	w.cl.next(quest.OpUpdate)
	w.cl.next(quest.OpTalkPage)
	w.cl.send(npctalk.OpEnd, npctalk.EncodeEntity(w.giver.UID))
	w.cl.next(npctalk.OpEndResult)
}

// Finding 8: the paid state must reach the store before anything is paid.
// The reward was paid while its write failed (a restart re-opened a paid
// quest: double pay). Now the take is refused, nothing is paid, and a later
// take pays once.
func TestReview785RewardRefusedWhenThePaidStateIsNotSaved(t *testing.T) {
	store := &reviewFailStore{Store: quest.NewMemStore()}
	w := startReviewQuestWorld(t, store)
	w.accept(t)
	e, _ := w.hub.FindByName("Aria")
	mob := combat.Monster{ID: 1, CodeName: "MOB_T"}
	questOnKill(w.ctx, e.Session, w.id, mob)
	w.cl.next(quest.OpUpdate)
	questOnKill(w.ctx, e.Session, w.id, mob)
	w.cl.next(quest.OpUpdate)
	w.openTalk(t)
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	w.cl.next(quest.OpRewardWindow)

	store.fail.Store(true)
	before, _ := w.chars.GetByID(w.ctx, w.id)
	take := append(binary.LittleEndian.AppendUint32(nil, 901), 0)
	w.cl.send(quest.OpTakeReward, take)
	if res := w.cl.next(quest.OpTakeRewardResult).Data; res[0] != 2 {
		t.Fatalf("take with the store failing: % x; want refused {2, ...}", res)
	}
	if after, _ := w.chars.GetByID(w.ctx, w.id); after.Gold != before.Gold {
		t.Fatalf("gold %d -> %d with the paid state unsaved", before.Gold, after.Gold)
	}
	ql, _ := questRT.Load().logOf(w.ctx, w.id)
	if s := ql.snapshot(901); s.Status != quest.StatusAchievedButNotPaid || s.Achieved != 0 {
		t.Fatalf("the log after the refused take: %+v; want still unpaid", s)
	}

	// The refused take ended the talk, as the original's does on every path
	// (s:0x51b370, round 819): the reward window is opened again.
	store.fail.Store(false)
	w.openTalk(t)
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	w.cl.next(quest.OpRewardWindow)
	w.cl.send(quest.OpTakeReward, take)
	if res := w.cl.next(quest.OpTakeRewardResult).Data; res[0] != 1 {
		t.Fatalf("take with the store back: % x", res)
	}
	if after, _ := w.chars.GetByID(w.ctx, w.id); after.Gold != before.Gold+100 {
		t.Fatalf("gold %d -> %d; want paid once", before.Gold, after.Gold)
	}
}

// Finding 14: a quest talk answers only near its NPC. An answer sent from
// far away still accepted the quest.
func TestReview785QuestTalkNotAnsweredFarFromTheNPC(t *testing.T) {
	w := startReviewQuestWorld(t, quest.NewMemStore())
	w.openTalk(t)
	w.moveTo(1500, 0)
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	w.cl.none(quest.OpTalkPage)
}

// Finding 14: the NPC talk's end (0x704B) ends the quest talk. The old talk
// still answered after it.
func TestReview785QuestTalkEndsWithTheNPCTalk(t *testing.T) {
	w := startReviewQuestWorld(t, quest.NewMemStore())
	w.openTalk(t)
	w.cl.send(npctalk.OpEnd, npctalk.EncodeEntity(w.giver.UID))
	w.cl.next(npctalk.OpEndResult)
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	w.cl.none(quest.OpTalkPage)
}

// Finding 14: a teleport ends the quest talk. Back beside the NPC, the old
// talk still answered.
func TestReview785QuestTalkEndsWithATeleport(t *testing.T) {
	w := startReviewQuestWorld(t, quest.NewMemStore())
	w.openTalk(t)
	w.cl.send(OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	if r, err := DecodeChangeZoneResult(w.cl.next(OpChangeZoneResult).Data); err != nil || !r.OK {
		t.Skipf("the zone change was refused (%v %+v)", err, r)
	}
	w.cl.send(OpChangeZone, (&ChangeZoneRequest{Zone: "jangan"}).Encode())
	if r, err := DecodeChangeZoneResult(w.cl.next(OpChangeZoneResult).Data); err != nil || !r.OK {
		t.Skipf("the zone change back was refused (%v %+v)", err, r)
	}
	if e, _ := w.hub.FindByName("Aria"); e.Zone != "jangan" {
		t.Skipf("back in %q, not jangan", e.Zone)
	}
	w.moveTo(50, 0)
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	w.cl.none(quest.OpTalkPage)
}
