package session

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The job guild (round 799; docs/protocol/jobs.md, "The job guild"). Every
// request names the NPC; the engine's first test (FUN_004e72a0: in reach and
// that NPC's interaction held, else the literal 3) is npcInteractions' state
// here, and its HasAvailableInteraction(npc, 0x14/0x15/0x16) the select's set.
//
//	0x70E1 join       CInstanceCharTrijob::HandleJoinJobGuild s:0x5120f0
//	0x70E2 withdraw   JobGuild_HandleWithdraw s:0x5122b0
//	0x70E3 alias      GObjPC_HandleAliasMsg_0e3 s:0x512540
//	0x70E4 ranking    s:0x512c20
//	0x70E5 reward     s:0x512e70
//	0x70E6 old job    s:0x513190
//
// The engine answers a join, an alias and the old-job query after an async
// DB call (AQ_Trijob); OpenSRO's stores answer at once, so the completion's
// work follows the handler's checks directly. Not modelled (OURS,
// disclosed): the trader's safe-trade record a join creates (AQ type 6,
// _InsertCharTrijobSafeTradeData; the shard's TRADE_SAFETY_OPTION is 0), the
// withdrawal's association-quest refusal 0x482e (CGObjPC::FUN_00572340 asks
// each active quest's slot 5; OpenSRO's quests carry no job type), and the
// exp multiplier at player +0x2280 (1.0 here).

type jobDeps struct {
	store   jobs.Store
	chars   character.Store
	eq      equipment.Store
	inv     inventory.Store
	items   ItemLookup
	parties *party.Hub
	hub     *world.Hub
	logger  *slog.Logger
}

var jobRT atomic.Pointer[jobDeps]

// JobDeps is what the job system reads (cmd/server).
type JobDeps struct {
	Store   jobs.Store
	Chars   character.Store
	Equip   equipment.Store
	Inv     inventory.Store
	Items   ItemLookup
	Parties *party.Hub
	Hub     *world.Hub
	Logger  *slog.Logger
}

// SetJobDeps installs the job store (cmd/server). A nil Store turns the job
// guild off: every request is refused 2.
func SetJobDeps(d JobDeps) {
	if d.Logger == nil {
		d.Logger = slog.Default()
	}
	jobRT.Store(&jobDeps{store: d.Store, chars: d.Chars, eq: d.Equip, inv: d.Inv, items: d.Items, parties: d.Parties,
		hub: d.Hub, logger: d.Logger})
}

func jobDepsNow() jobDeps {
	if d := jobRT.Load(); d != nil {
		return *d
	}
	return jobDeps{logger: slog.Default()}
}

// jobLocks serializes one character's job requests (the engine's one
// pending async query per player).
var jobLocks sync.Map // int64 -> *sync.Mutex

func jobLock(characterID int64) *sync.Mutex {
	m, _ := jobLocks.LoadOrStore(characterID, &sync.Mutex{})
	return m.(*sync.Mutex)
}

// jobRecs caches the records of the characters in the world (the engine
// keeps the record on the player object, player+0x1fb8); every write goes
// through saveJobRecord / setJobAlias, and a leave drops the entry.
var jobRecs sync.Map // int64 -> jobs.Record

// jobRecord is characterID's record (NewRecord with no store).
func jobRecord(ctx context.Context, characterID int64) jobs.Record {
	if v, ok := jobRecs.Load(characterID); ok {
		return v.(jobs.Record)
	}
	d := jobDepsNow()
	if d.store == nil {
		return jobs.NewRecord(characterID)
	}
	r, err := d.store.Get(ctx, characterID)
	if err != nil {
		d.logger.Warn("jobs: reading a record failed", "character", characterID, "err", err)
		return jobs.NewRecord(characterID)
	}
	jobRecs.Store(characterID, r)
	return r
}

// saveJobRecord writes a record (the alias left as the store holds it) and
// caches it.
func saveJobRecord(ctx context.Context, d jobDeps, r jobs.Record) error {
	if err := d.store.Save(ctx, r); err != nil {
		jobRecs.Delete(r.CharID)
		return err
	}
	if cur, ok := jobRecs.Load(r.CharID); ok {
		r.Alias = cur.(jobs.Record).Alias
	}
	jobRecs.Store(r.CharID, r)
	return nil
}

// setJobAlias writes an alias and caches it.
func setJobAlias(ctx context.Context, d jobDeps, characterID int64, alias string) error {
	if err := d.store.SetAlias(ctx, characterID, alias); err != nil {
		return err
	}
	r := jobRecord(ctx, characterID)
	r.Alias = alias
	jobRecs.Store(characterID, r)
	return nil
}

// forgetJobRecord drops a leaving character's cached record.
func forgetJobRecord(characterID int64) { jobRecs.Delete(characterID) }

// wornJobState is the job state characterID's worn slot-8 suit gives:
// 1 trader, 2 thief, 3 hunter, 4 none (GetJobState, chardata+0xf).
func wornJobState(ctx context.Context, characterID int64) byte {
	d := jobDepsNow()
	if d.eq == nil {
		return pcspawn.JobStateNone
	}
	for _, it := range equippedItems(ctx, d.eq, characterID) {
		if equipment.Slot(it.Slot) == equipment.SlotJobSuit {
			return jobStateOf(ctx, it.ItemID)
		}
	}
	return pcspawn.JobStateNone
}

// jobGuildNPC is FUN_004e72a0 then the guild id test: ok false answers 3;
// offered false answers 0x480f (the NPC is not that guild's).
func jobGuildNPC(sess *gateway.Session, e world.Entity, npcUID uint32, guildID byte) (ok, offered bool) {
	st := npcInteractionOf(sess.ID())
	npcInteractions.mu.Lock()
	held := st.entity == npcUID && (st.selected || st.mode != 0)
	ids := append([]byte(nil), st.ids...)
	npcInteractions.mu.Unlock()
	if !held {
		return false, false
	}
	if _, code := npcTarget(e, npcUID); code != 0 {
		return false, false
	}
	if guildID == 0 {
		return true, true
	}
	for _, b := range ids {
		if b == guildID {
			return true, true
		}
	}
	return true, false
}

// guildID is the interaction id of a kind's job guild (0 for none).
func guildID(k jobs.Kind) byte {
	id, ok := k.ID()
	if !ok {
		return 0
	}
	return byte(id)
}

// JobGuildHandler answers 0x70E1..0x70E6.
func JobGuildHandler(hub *world.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case jobs.OpJoin, jobs.OpWithdraw, jobs.OpAlias, jobs.OpRanking, jobs.OpReward, jobs.OpPrevJob:
		default:
			return nil
		}
		e, ok := hub.EntityBySession(sess.ID())
		if !ok {
			return nil
		}
		req, err := jobs.DecodeRequest(p.Opcode, p.Data)
		if err != nil {
			return nil
		}
		d := jobDepsNow()
		lk := jobLock(e.CharacterID)
		lk.Lock()
		defer lk.Unlock()
		send := func(op uint16, b []byte) error { return sess.Send(&proto.Packet{Opcode: op, Data: b}) }
		if d.store == nil {
			switch p.Opcode {
			case jobs.OpAlias:
				return send(jobs.OpAliasResult, jobs.AliasFail(jobs.ErrDB, req.Op, req.Alias))
			case jobs.OpRanking:
				return send(jobs.OpRankingResult, jobs.RankingFail(jobs.ErrDB, req.Kind, req.Type))
			case jobs.OpReward:
				return send(jobs.OpRewardResult, jobs.RewardFail(jobs.ErrDB, req.Op))
			}
			return send(p.Opcode+0x4000, jobs.Fail(jobs.ErrDB)) // 0x70Ex -> 0xB0Ex
		}
		switch p.Opcode {
		case jobs.OpJoin:
			return send(jobs.OpJoinResult, jobJoin(ctx, sess, d, e, req))
		case jobs.OpWithdraw:
			return send(jobs.OpWithdrawAck, jobWithdraw(ctx, sess, d, e, req))
		case jobs.OpAlias:
			return send(jobs.OpAliasResult, jobAlias(ctx, sess, d, e, req))
		case jobs.OpRanking:
			return send(jobs.OpRankingResult, jobRanking(ctx, sess, d, e, req))
		case jobs.OpReward:
			return send(jobs.OpRewardResult, jobReward(ctx, sess, d, e, req))
		case jobs.OpPrevJob:
			return send(jobs.OpPrevJobResult, jobPrevJob(ctx, sess, d, e, req))
		}
		return nil
	}
}

func charOf(ctx context.Context, d jobDeps, characterID int64) (*character.Character, bool) {
	if d.chars == nil {
		return nil, false
	}
	c, err := d.chars.GetByID(ctx, characterID)
	if err != nil || c == nil {
		return nil, false
	}
	return c, true
}

// jobCharge takes a fee (OffsetGold(-fee, reason, notify 1, show 0): READ
// s:0x4e7a4a..0x4e7a5d for the join; the alias change the same with reason
// 0xe). OffsetGold floors gold at 0, so a fee the gold no longer covers takes
// what is there.
func jobCharge(ctx context.Context, d jobDeps, characterID, fee, have int64) {
	if fee <= 0 {
		return
	}
	if fee > have {
		fee = have
	}
	if fee > 0 {
		if err := d.chars.DeductGold(ctx, characterID, fee); err != nil {
			d.logger.Warn("jobs: charging a fee failed", "character", characterID, "fee", fee, "err", err)
			return
		}
	}
	tellGold(ctx, d.chars, d.hub, characterID, false)
}

// jobJoin is 0x70E1, its checks in the handler's order (s:0x5120f0) and its
// completion's work (s:0x4e7a08): the fee, the record from the previous job
// information (_QueryOldTrijobInfo: level 1, exp 0 when there is none), then
// that information deleted (AQ type 4).
func jobJoin(ctx context.Context, sess *gateway.Session, d jobDeps, e world.Entity, req jobs.Request) []byte {
	held, _ := jobGuildNPC(sess, e, req.NPC, 0)
	if !held {
		return jobs.Fail(jobs.ErrNPC)
	}
	if !req.Kind.Valid() {
		return jobs.Fail(jobs.ErrUnknownJobKind)
	}
	if _, offered := jobGuildNPC(sess, e, req.NPC, guildID(req.Kind)); !offered {
		return jobs.Fail(jobs.ErrJobGuildNotFound)
	}
	c, ok := charOf(ctx, d, e.CharacterID)
	if !ok {
		return jobs.Fail(jobs.ErrDB)
	}
	if c.Level < jobs.MinJobLevel {
		return jobs.Fail(jobs.ErrJobGuildLevel)
	}
	rec := jobRecord(ctx, e.CharacterID)
	if rec.HasJob() {
		return jobs.Fail(jobs.ErrJobOverlap)
	}
	fee := jobs.JoinFee(c.Level)
	if c.Gold < fee {
		return jobs.Fail(jobs.ErrNotEnoughGold)
	}
	if rec.Penalized(time.Now()) {
		return jobs.Fail(jobs.ErrJoinPenalty)
	}
	level, exp := 1, int64(0)
	if old, err := d.store.OldJob(ctx, e.CharacterID); err == nil {
		i := int(req.Kind) - 1
		level, exp = old.Level[i], old.Exp[i]
	} else if !errors.Is(err, jobs.ErrNoOldJob) {
		return jobs.Fail(jobs.ErrDB)
	}
	rec.Kind, rec.Level, rec.Exp = req.Kind, level, exp
	if err := saveJobRecord(ctx, d, rec); err != nil {
		d.logger.Warn("jobs: saving a join failed", "character", e.CharacterID, "err", err)
		return jobs.Fail(jobs.ErrDB)
	}
	jobCharge(ctx, d, e.CharacterID, fee, c.Gold)
	if err := d.store.DeleteOldJob(ctx, e.CharacterID); err != nil {
		d.logger.Warn("jobs: deleting the old job failed", "character", e.CharacterID, "err", err)
	}
	d.logger.Info("jobs: joined", "character", e.CharacterID, "kind", req.Kind.Name(), "fee", fee)
	return jobs.JoinOK(rec.Kind, rec.Level, rec.Exp)
}

// jobWithdraw is 0x70E2 (s:0x5122b0): own guild's NPC, no suit worn; then the
// 7-day timed job, the record reset (FUN_0060db70: kind 0, level 1, exp,
// contribution and reward 0 -- an unclaimed reward is lost) and the alias
// cleared (CGObjPC::FUN_004ddbc0("")).
func jobWithdraw(ctx context.Context, sess *gateway.Session, d jobDeps, e world.Entity, req jobs.Request) []byte {
	return jobWithdrawNPC(ctx, sess, d, e, req.NPC, time.Now())
}

func jobWithdrawNPC(ctx context.Context, sess *gateway.Session, d jobDeps, e world.Entity, npc uint32, now time.Time) []byte {
	held, _ := jobGuildNPC(sess, e, npc, 0)
	if !held {
		return jobs.Fail(jobs.ErrNPC)
	}
	rec := jobRecord(ctx, e.CharacterID)
	if !rec.HasJob() {
		return jobs.Fail(jobs.ErrUnknownJobKind)
	}
	if _, offered := jobGuildNPC(sess, e, npc, guildID(rec.Kind)); !offered {
		return jobs.Fail(jobs.ErrJobGuildNotFound)
	}
	if wornJobState(ctx, e.CharacterID) != pcspawn.JobStateNone {
		return jobs.Fail(jobs.ErrSuitWorn)
	}
	old := rec
	rec = jobs.NewRecord(e.CharacterID)
	rec.PenaltyUntil = now.Add(jobs.PenaltySeconds * time.Second)
	if err := saveJobRecord(ctx, d, rec); err != nil {
		d.logger.Warn("jobs: saving a withdrawal failed", "character", e.CharacterID, "err", err)
		return jobs.Fail(jobs.ErrDB)
	}
	if err := setJobAlias(ctx, d, e.CharacterID, ""); err != nil {
		d.logger.Warn("jobs: clearing the alias failed", "character", e.CharacterID, "err", err)
	}
	d.logger.Info("jobs: withdrew", "character", e.CharacterID, "alias", old.Alias, "kind", old.Kind.Name(),
		"level", old.Level, "exp", old.Exp, "contribution", old.Contribution)
	return jobs.WithdrawOK()
}

// jobAlias is 0x70E3 (s:0x512540; completions s:0x4e7d74 check, s:0x4e7e4e
// set).
func jobAlias(ctx context.Context, sess *gateway.Session, d jobDeps, e world.Entity, req jobs.Request) []byte {
	fail := func(code uint16) []byte { return jobs.AliasFail(code, req.Op, req.Alias) }
	held, _ := jobGuildNPC(sess, e, req.NPC, 0)
	if !held {
		return fail(jobs.ErrNPC)
	}
	rec := jobRecord(ctx, e.CharacterID)
	if !rec.HasJob() {
		return fail(jobs.ErrUnknownJobKind)
	}
	if _, offered := jobGuildNPC(sess, e, req.NPC, guildID(rec.Kind)); !offered {
		return fail(jobs.ErrJobGuildNotFound)
	}
	if wornJobState(ctx, e.CharacterID) != pcspawn.JobStateNone {
		return fail(jobs.ErrSuitWorn)
	}
	if !aliasAllowed(req.Alias) {
		return fail(jobs.ErrAliasRule)
	}
	switch req.Op {
	case 0:
		free, err := d.store.AliasFree(ctx, e.CharacterID, req.Alias)
		if err != nil {
			return fail(jobs.ErrDB)
		}
		if !free {
			return fail(jobs.ErrAliasTaken1)
		}
		return jobs.AliasOK(0, req.Alias)
	case 1:
		if n := len(req.Alias); n < jobs.AliasMinLen || n > jobs.AliasMaxLen {
			return fail(jobs.ErrAliasRule)
		}
		c, ok := charOf(ctx, d, e.CharacterID)
		if !ok {
			return fail(jobs.ErrDB)
		}
		var fee int64
		if rec.Alias != "" {
			fee = jobs.AliasChangeFee(c.Level)
			if c.Gold < fee {
				return fail(jobs.ErrNotEnoughGold)
			}
		}
		if err := setJobAlias(ctx, d, e.CharacterID, req.Alias); err != nil {
			if errors.Is(err, jobs.ErrAliasTaken) {
				return fail(jobs.ErrAliasTaken1)
			}
			return fail(jobs.ErrDB)
		}
		jobCharge(ctx, d, e.CharacterID, fee, c.Gold)
		d.logger.Info("jobs: alias", "character", e.CharacterID, "from", rec.Alias, "to", req.Alias, "fee", fee)
		return jobs.AliasOK(1, req.Alias)
	}
	return fail(jobs.ErrJobGuildNotFound)
}

// aliasAllowed is FUN_004184a0, the COS name's validator too (READ the
// callers): no space, then the name filter.
func aliasAllowed(alias string) bool {
	if alias == "" || !cos.ValidPetName(alias) {
		return false
	}
	if f := nameFilter.Load(); f != nil && !f.NameOK(alias) {
		return false
	}
	return true
}

// jobRanking is 0x70E4 (s:0x512c20): no guild-id test, only the NPC's.
func jobRanking(ctx context.Context, sess *gateway.Session, d jobDeps, e world.Entity, req jobs.Request) []byte {
	if held, _ := jobGuildNPC(sess, e, req.NPC, 0); !held {
		return jobs.RankingFail(jobs.ErrNPC, req.Kind, req.Type)
	}
	if !req.Kind.Valid() {
		return jobs.RankingFail(jobs.ErrUnknownJobKind, req.Kind, req.Type)
	}
	if req.Type != jobs.RankActivity && req.Type != jobs.RankContribution {
		return jobs.RankingFail(jobs.ErrJobGuildNotFound, req.Kind, req.Type)
	}
	rows, err := d.store.Rankings(ctx, req.Kind, req.Type)
	if err != nil {
		return jobs.RankingFail(jobs.ErrDB, req.Kind, req.Type)
	}
	return jobs.RankingOK(req.Kind, req.Type, rows)
}

// jobReward is 0x70E5 (s:0x512e70): a robber or hunter at its guild; op 0
// tells the reward, op 1 pays it (OffsetGold reason 0xc) and zeroes it. The
// reply's amount is the one paid, which the client keeps as its reward
// (READ both sides: a retail quirk, kept).
func jobReward(ctx context.Context, sess *gateway.Session, d jobDeps, e world.Entity, req jobs.Request) []byte {
	if held, _ := jobGuildNPC(sess, e, req.NPC, 0); !held {
		return jobs.RewardFail(jobs.ErrNPC, req.Op)
	}
	rec := jobRecord(ctx, e.CharacterID)
	if rec.Kind != jobs.KindThief && rec.Kind != jobs.KindHunter {
		return jobs.RewardFail(jobs.ErrUnknownJobKind, req.Op)
	}
	if _, offered := jobGuildNPC(sess, e, req.NPC, guildID(rec.Kind)); !offered || req.Op > 1 {
		return jobs.RewardFail(jobs.ErrJobGuildNotFound, req.Op)
	}
	if req.Op == 0 {
		return jobs.RewardOK(0, rec.Reward)
	}
	if rec.Reward == 0 {
		return jobs.RewardFail(jobs.ErrNoReward, req.Op)
	}
	paid := rec.Reward
	rec.Reward = 0
	if err := saveJobRecord(ctx, d, rec); err != nil {
		return jobs.RewardFail(jobs.ErrDB, req.Op)
	}
	if err := d.chars.AddGold(ctx, e.CharacterID, paid); err != nil {
		d.logger.Warn("jobs: paying a reward failed", "character", e.CharacterID, "gold", paid, "err", err)
	}
	tellGold(ctx, d.chars, d.hub, e.CharacterID, false)
	d.logger.Info("jobs: reward paid", "character", e.CharacterID, "gold", paid)
	return jobs.RewardOK(1, paid)
}

// jobPrevJob is 0x70E6 (s:0x513190, completion s:0x4e8033).
func jobPrevJob(ctx context.Context, sess *gateway.Session, d jobDeps, e world.Entity, req jobs.Request) []byte {
	if held, _ := jobGuildNPC(sess, e, req.NPC, 0); !held {
		return jobs.Fail(jobs.ErrNPC)
	}
	old, err := d.store.OldJob(ctx, e.CharacterID)
	if errors.Is(err, jobs.ErrNoOldJob) {
		return jobs.Fail(jobs.ErrNoOldJobInfo)
	}
	if err != nil {
		return jobs.Fail(jobs.ErrDB)
	}
	return jobs.PrevJobOK(old)
}

// sendJobInfo is OpJobInfo to characterID's own client (world entry).
func sendJobInfo(ctx context.Context, sess *gateway.Session, characterID int64) {
	if sess == nil || jobDepsNow().store == nil {
		return
	}
	_ = sess.Send(&proto.Packet{Opcode: jobs.OpJobInfo, Data: jobs.JobInfo(jobRecord(ctx, characterID))})
}

// gainJobExp is FUN_004e2830: a job exp change for characterID, saved, and
// 0x30E6 to its client when the record changed.
func gainJobExp(ctx context.Context, characterID int64, amount int64) {
	d := jobDepsNow()
	if d.store == nil || amount == 0 {
		return
	}
	lk := jobLock(characterID)
	lk.Lock()
	rec := jobRecord(ctx, characterID)
	changed := jobs.GainExp(&rec, amount, jobNeed)
	if changed {
		if err := saveJobRecord(ctx, d, rec); err != nil {
			d.logger.Warn("jobs: saving job exp failed", "character", characterID, "err", err)
		}
	}
	lk.Unlock()
	if changed {
		if e, ok := entityOf(d.hub, characterID); ok && e.Session != nil {
			_ = e.Session.Send(&proto.Packet{Opcode: jobs.OpJobExp, Data: jobs.JobExp(rec)})
		}
	}
}

// jobNeed reads the level table's job columns.
func jobNeed(level int, kind jobs.Kind) (uint32, bool) {
	return levelTable.JobNeed(level, int(kind))
}

// StartJobWeekly runs jobs.Weekly every week on day (a weekday's English
// name, "off" never) at hour, local time (round 799; OURS: the schedule,
// retail's procedure runs outside the GameServer, INFERRED a SQL Agent job).
func StartJobWeekly(ctx context.Context, day string, hour int, logger *slog.Logger) {
	if logger == nil {
		logger = slog.Default()
	}
	wd, ok := weekdayOf(day)
	if !ok || hour < 0 || hour > 23 {
		if day != "off" {
			logger.Warn("jobs: -job-week-day/-job-week-hour not understood; the weekly job procedure does not run", "day", day, "hour", hour)
		}
		return
	}
	go func() {
		for {
			now := time.Now()
			next := nextWeekly(now, wd, hour)
			select {
			case <-ctx.Done():
				return
			case <-time.After(next.Sub(now)):
			}
			if err := RunJobWeekly(ctx); err != nil {
				logger.Warn("jobs: the weekly procedure failed", "err", err)
			} else {
				logger.Info("jobs: the weekly procedure ran")
			}
		}
	}()
}

// RunJobWeekly runs jobs.Weekly now (the schedule, and the GM's /jobweek).
func RunJobWeekly(ctx context.Context) error {
	d := jobDepsNow()
	if d.store == nil {
		return errors.New("jobs: no job store")
	}
	err := jobs.Weekly(ctx, d.store, func(id int64) uint8 { return countryOf(ctx, d.chars, id) })
	// The procedure wrote the store directly: the cached records are stale.
	jobRecs.Range(func(k, _ any) bool { jobRecs.Delete(k); return true })
	return err
}

// countryOf is _RefObjCommon.Country of the character's body: 0 Chinese, 1
// European (the activity tables' column; characterCountry).
func countryOf(ctx context.Context, chars character.Store, id int64) uint8 {
	if chars == nil {
		return 0
	}
	c, err := chars.GetByID(ctx, id)
	if err != nil || c == nil {
		return 0
	}
	if characterCountry(c) == equipment.CountryEurope {
		return 1
	}
	return 0
}

func weekdayOf(s string) (time.Weekday, bool) {
	for d := time.Sunday; d <= time.Saturday; d++ {
		if strings.EqualFold(d.String(), s) {
			return d, true
		}
	}
	return 0, false
}

// nextWeekly is the first time after now that falls on wd at hour:00.
func nextWeekly(now time.Time, wd time.Weekday, hour int) time.Time {
	t := time.Date(now.Year(), now.Month(), now.Day(), hour, 0, 0, 0, now.Location())
	for t.Weekday() != wd || !t.After(now) {
		t = t.AddDate(0, 0, 1)
	}
	return t
}

// gmJobs is gm.JobControl (round 799, OURS: /jobexp and /jobweek).
type gmJobs struct{}

func (gmJobs) GainJobExp(ctx context.Context, characterID int64, amount int64) string {
	if jobDepsNow().store == nil {
		return "no job store"
	}
	if !jobRecord(ctx, characterID).HasJob() {
		return "not in a job guild"
	}
	gainJobExp(ctx, characterID, amount)
	r := jobRecord(ctx, characterID)
	return fmt.Sprintf("%s level %d, exp %d, contribution %d", r.Kind.Name(), r.Level, r.Exp, r.Contribution)
}

func (gmJobs) RunWeekly(ctx context.Context) error { return RunJobWeekly(ctx) }
