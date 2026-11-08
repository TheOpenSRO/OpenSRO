package academy

import (
	"context"
	"errors"
	"sort"
	"time"
)

// Round 865 stage 2: the academy's persistent state, the four tables of
// docs/protocol/academy.md section 3 plus the honor bank and the date of the
// last honor-rank update. The rules each Store method applies are the
// store's own (MEASURED as the stored rules; the calls READ in the shard
// manager's query strings); MemStore and SQLStore apply the same ones, and
// store_test.go runs every rule against both.

// Camp is one _TRAININGCAMP row and its members.
type Camp struct {
	ID int64
	// CreationDate is minute-rounded (MEASURED: the column is a small
	// date-time; Minute).
	CreationDate time.Time
	// Rank is the honor rank 1..5, RankNone (5) unranked.
	Rank                 int
	GraduateCount        int
	EvaluationPoint      int
	LatestEvaluationDate time.Time
	// NoticeTitle and Notice are CommentTitle and Comment ("" for none).
	NoticeTitle, Notice string
	// Members is the guardian first, then the others in join order
	// (MEASURED: the order every CampInfo lists them in).
	Members []Member
}

// Member is one _TRAININGCAMPMEMBER row.
type Member struct {
	CampID   int64
	CharID   int64
	RefObjID int64
	Name     string
	// JoinDate is minute-rounded, as CreationDate.
	JoinDate time.Time
	// Class is MemberClassGuardian (0), MemberClassSecondGuardian (1) or
	// MemberClassStudent (2).
	Class int
	// JoinedLevel is the max level at joining; CurLevel and MaxLevel follow
	// the character only when its level changes in the game (SetLevels).
	JoinedLevel, CurLevel, MaxLevel int
	Honor                           int
}

// Guardian is the camp's class-0 member, if any.
func (c *Camp) Guardian() (Member, bool) {
	for _, m := range c.Members {
		if m.Class == MemberClassGuardian {
			return m, true
		}
	}
	return Member{}, false
}

// Member is the member with charID.
func (c *Camp) Member(charID int64) (Member, bool) {
	for _, m := range c.Members {
		if m.CharID == charID {
			return m, true
		}
	}
	return Member{}, false
}

// Count is how many members of class the camp holds.
func (c *Camp) Count(class int) int {
	n := 0
	for _, m := range c.Members {
		if m.Class == class {
			n++
		}
	}
	return n
}

// BuffRow is one _TRAININGCAMPBUFFSTATUS row.
type BuffRow struct {
	CampID      int64
	RecipientID int64
	Slot        int
	DonorID     int64
	Start       time.Time
	Points      int
	Type        int
}

// Joiner is the character a camp is founded by or a member added from.
type Joiner struct {
	CharID   int64
	RefObjID int64
	Name     string
	CurLevel int
	MaxLevel int
}

// HonorShare is a member's new HonorPoint total after a graduation paid it.
type HonorShare struct {
	CharID int64
	Honor  int
}

// Graduation is what a graduation did.
type Graduation struct {
	Member Member
	// Shares are the guardian's and the assistants' new totals, in camp
	// order, when the graduate was an apprentice who joined at
	// HonorJoinLevelCeiling or below; empty otherwise.
	Shares []HonorShare
}

// RankRow is one _TRAININGCAMPHONORRANK row.
type RankRow struct {
	Ranking int
	CampID  int64
	Rank    int
}

// RankChange is a camp whose Rank an update changed.
type RankChange struct {
	CampID int64
	Rank   int
}

// The store's refusals.
var (
	ErrNotInCamp      = errors.New("academy: not in an academy")
	ErrInCamp         = errors.New("academy: already in an academy")
	ErrNoSuchCamp     = errors.New("academy: no such academy")
	ErrGuardian       = errors.New("academy: the guardian cannot do that")
	ErrGuardianExists = errors.New("academy: the academy has its guardian")
	ErrAssistantsFull = errors.New("academy: the assistant guardians are full")
	ErrApprenticeFull = errors.New("academy: the apprentices are full")
	ErrHonorShort     = errors.New("academy: not enough honor points")
)

// Store keeps the academies.
type Store interface {
	// Found makes a camp (Rank 5, GraduateCount 0, EvaluationPoint 0,
	// LatestEvaluationDate = CreationDate = now, no notice) and adds the
	// founder as AddMember does.
	Found(ctx context.Context, j Joiner, now time.Time) (*Camp, error)
	// AddMember adds j: refused when j is in any camp (ErrInCamp); its class
	// from its max level (ClassForMaxLevel), refusing a second guardian, a
	// third assistant and a sixth apprentice; JoinDate now; CharJoinedLevel
	// its max level; HonorPoint the banked points (the bank row removed);
	// the class's buff rows (BuffRowsFor).
	AddMember(ctx context.Context, campID int64, j Joiner, now time.Time) (*Camp, error)
	// RemoveMember removes charID (never the guardian, ErrGuardian) for
	// reason RemoveLeft, RemoveBanned or RemoveSilent: an assistant's points
	// are banked, less AssistantLeavePenalty unless banned; an apprentice's
	// buff rows are deleted. Returns the camp after and the member removed.
	RemoveMember(ctx context.Context, charID int64, reason int) (*Camp, Member, error)
	// Graduate removes charID as a graduate: an assistant's points banked;
	// an apprentice's graduation pays the honor shares and, when it joined
	// at HonorJoinLevelCeiling or below, GraduateCount += 1, EvaluationPoint
	// += points and LatestEvaluationDate = now; otherwise only
	// GraduateCount += 1. The member row and (apprentice) buff rows go.
	Graduate(ctx context.Context, charID int64, points int, now time.Time) (*Camp, Graduation, error)
	// Disband banks every assistant's points (> 0) and deletes the camp,
	// its members and its buff rows. Returns the members it had.
	Disband(ctx context.Context, campID int64) ([]Member, error)
	// SetNotice sets the camp's notice.
	SetNotice(ctx context.Context, campID int64, title, content string) error
	// SetLevels sets charID's CharCurLevel / CharMaxLevel (a level change in
	// the game; ErrNotInCamp when it is in none).
	SetLevels(ctx context.Context, charID int64, cur, max int) error
	// SetRefObj and SetName follow a body change and a rename.
	SetRefObj(ctx context.Context, charID, refObjID int64) error
	SetName(ctx context.Context, charID int64, name string) error
	// SpendHonor takes amount from charID's HonorPoint (ErrNotInCamp,
	// ErrHonorShort). pay runs before the points go; its error leaves
	// them. Returns the new total.
	SpendHonor(ctx context.Context, charID int64, amount int, pay func() error) (int, error)
	// CampOf is charID's camp (ErrNotInCamp).
	CampOf(ctx context.Context, charID int64) (*Camp, error)
	// Get is a camp by id (ErrNoSuchCamp).
	Get(ctx context.Context, campID int64) (*Camp, error)
	// BuffRows are charID's buff rows, by type then slot.
	BuffRows(ctx context.Context, charID int64) ([]BuffRow, error)
	// Bank is charID's banked honor points (0 for none).
	Bank(ctx context.Context, charID int64) (int, error)
	// UpdateRanks re-ranks every camp (RankCamps), stores the ranking rows
	// and the update's date, and returns the camps whose Rank changed.
	UpdateRanks(ctx context.Context, now time.Time) ([]RankChange, error)
	// Ranking is the stored ranking rows, by Ranking.
	Ranking(ctx context.Context) ([]RankRow, error)
	// LastRankUpdate is when UpdateRanks last ran (zero for never).
	LastRankUpdate(ctx context.Context) (time.Time, error)
}

// Removal reasons (0x3C80 sub 3's byte, READ s:0x5ddc44; 3 the shard
// manager's silent removal, s:0x4566d0, used for a deleted character).
const (
	RemoveLeft   = 1
	RemoveBanned = 2
	RemoveSilent = 3
)

// RankNone is the unranked honor rank (MEASURED: a new camp's Rank 5; the
// client draws com_honor_level_5).
const RankNone = 5

// AssistantLeavePenalty is the honor an assistant guardian loses when it
// leaves (or is removed silently) rather than being banned (MEASURED as the
// stored rule), floored at 0.
const AssistantLeavePenalty = 10

// BuffStartNone is an idle buff row's StartingTime, 2000-01-01 (READ
// s:0x5e1cb1 `0x107d0, 1, 0`; MEASURED in the rows a founding writes).
var BuffStartNone = time.Date(2000, 1, 1, 0, 0, 0, 0, time.Local)

// Minute rounds t to the minute as the store's small date-time does
// (MEASURED: founded at :08:02 -> :08:00, joined at :24:41 -> :25:00).
func Minute(t time.Time) time.Time {
	return t.Round(time.Minute)
}

// ClassForMaxLevel is the class the store derives from a max level (MEASURED
// as the store's rule): below 40 an apprentice, below 60 an assistant, else
// the guardian.
func ClassForMaxLevel(max int) int {
	switch {
	case max < 40:
		return MemberClassStudent
	case max < 60:
		return MemberClassSecondGuardian
	}
	return MemberClassGuardian
}

// checkAdd is AddMember's caps for class in c.
func checkAdd(c *Camp, class int) error {
	switch class {
	case MemberClassGuardian:
		if c.Count(MemberClassGuardian) > 0 {
			return ErrGuardianExists
		}
	case MemberClassSecondGuardian:
		if c.Count(MemberClassSecondGuardian) >= MaxSecondGuardians {
			return ErrAssistantsFull
		}
	case MemberClassStudent:
		if c.Count(MemberClassStudent) >= MaxStudents {
			return ErrApprenticeFull
		}
	}
	return nil
}

// BuffRowsFor is the buff rows AddMember writes for a member of class
// (MEASURED, the rows after a founding and an apprentice's join): a guardian
// or an apprentice one BuffType 0 slot 0 row; a guardian also BuffType 3
// slots 1..5, an apprentice BuffType 3 slot 1; each idle (BuffStartNone, 0
// points, no donor). An assistant gets none.
func BuffRowsFor(campID, charID int64, class int) []BuffRow {
	row := func(slot, typ int) BuffRow {
		return BuffRow{CampID: campID, RecipientID: charID, Slot: slot, Start: BuffStartNone, Type: typ}
	}
	switch class {
	case MemberClassGuardian:
		out := []BuffRow{row(0, 0)}
		for s := 1; s <= 5; s++ {
			out = append(out, row(s, 3))
		}
		return out
	case MemberClassStudent:
		return []BuffRow{row(0, 0), row(1, 3)}
	}
	return nil
}

// bankAfterRemoval is what an assistant's points leave in the bank when it is
// removed for reason (an apprentice and the guardian bank nothing).
func bankAfterRemoval(m Member, reason int) int {
	if m.Class != MemberClassSecondGuardian {
		return 0
	}
	if reason == RemoveBanned {
		return m.Honor
	}
	return max(m.Honor-AssistantLeavePenalty, 0)
}

// The honor ranking (MEASURED as the stored rule): the top RankedCamps camps
// with EvaluationPoint >= RankMinPoints, ordered by EvaluationPoint
// descending, then LatestEvaluationDate ascending; places 1-5 rank 1, 6-15
// rank 2, 16-30 rank 3, 31-50 rank 4; every other camp RankNone.
const (
	RankedCamps   = 50
	RankMinPoints = 10
)

// RankForPlace is the rank of ranking place (1-based).
func RankForPlace(place int) int {
	switch {
	case place >= 1 && place <= 5:
		return 1
	case place <= 15:
		return 2
	case place <= 30:
		return 3
	case place <= RankedCamps:
		return 4
	}
	return RankNone
}

// RankCamps is the ranking of camps: the rows, and each camp's new Rank. Ties
// past LatestEvaluationDate fall to the camp id (OURS: the store's order for
// equal dates is not read).
func RankCamps(camps []*Camp) ([]RankRow, map[int64]int) {
	var eligible []*Camp
	ranks := map[int64]int{}
	for _, c := range camps {
		ranks[c.ID] = RankNone
		if c.EvaluationPoint >= RankMinPoints {
			eligible = append(eligible, c)
		}
	}
	sort.SliceStable(eligible, func(i, j int) bool {
		a, b := eligible[i], eligible[j]
		if a.EvaluationPoint != b.EvaluationPoint {
			return a.EvaluationPoint > b.EvaluationPoint
		}
		if !a.LatestEvaluationDate.Equal(b.LatestEvaluationDate) {
			return a.LatestEvaluationDate.Before(b.LatestEvaluationDate)
		}
		return a.ID < b.ID
	})
	var rows []RankRow
	for i, c := range eligible {
		if i >= RankedCamps {
			break
		}
		r := RankForPlace(i + 1)
		rows = append(rows, RankRow{Ranking: i + 1, CampID: c.ID, Rank: r})
		ranks[c.ID] = r
	}
	return rows, ranks
}

// RankUpdateDue reports whether the daily update owes a run at now: never run,
// or last run before today's 00:00:00 (MEASURED: the schedule row is daily at
// 00:00:00, and the shard catches up at start when the last update was not
// today).
func RankUpdateDue(last, now time.Time) bool {
	if last.IsZero() {
		return true
	}
	y, m, d := now.Date()
	return last.Before(time.Date(y, m, d, 0, 0, 0, 0, now.Location()))
}

// NextRankUpdate is the next 00:00:00 after now.
func NextRankUpdate(now time.Time) time.Time {
	y, m, d := now.Date()
	return time.Date(y, m, d+1, 0, 0, 0, 0, now.Location())
}

// sortMembers puts the guardian first, then by join order (seq).
func sortMembers(ms []Member, seq func(Member) int64) {
	sort.SliceStable(ms, func(i, j int) bool {
		gi, gj := ms[i].Class == MemberClassGuardian, ms[j].Class == MemberClassGuardian
		if gi != gj {
			return gi
		}
		return seq(ms[i]) < seq(ms[j])
	})
}
