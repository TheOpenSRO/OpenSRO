package nest

import (
	"math/rand"
	"sync"
	"time"
)

// Slot is one nest at run time: what the hive pass reads of its row and the
// per-nest slot CMainProcess::BuildHiveNestSlots (0x54bbf0) builds for it,
// {stamp, base, alive, pct, variance, col17 == 0, col16, col14} (READ, round
// 239). A stand-in nest -- an npcpos row with no DB nest -- is a Slot too,
// with the OURS numbers cmd/server gives it.
type Slot struct {
	// ID is the DB nest id, 0 for a stand-in.
	ID int64
	// Hive is the nest's hive, nil for none.
	Hive *Hive
	// Cap is col 14, the alive cap (and, with Respawn off, the budget).
	Cap int
	// Respawn is col 16 != 0; Active is col 17 == 0.
	Respawn, Active bool
	// Budget is how many hatches a non-respawning nest has left.
	Budget int
	// DelayMin/DelayMax are the respawn window in seconds (cols 12/13, or the
	// operator's override).
	DelayMin, DelayMax int
	// GenerateRadius is col 10, how far from the nest a hatch lands.
	GenerateRadius float64
	// Input is what the class roll reads (the species' rank and TypeID4, the
	// tactics' champion row, the nest's champion chance); PartyArmed is kept
	// in it.
	Input HatchInput
	// Level is the species' level, for the world's class clamp.
	Level int
	// Data is the caller's: what to hatch and where.
	Data any
	// Index is the nest's place among its hive's nests, in the order they
	// were added (Scheduler.Add sets it): the index the unique rotation's
	// dice pick (round 661).
	Index int

	stamp  time.Time
	baseMs int
	alive  int
}

// Alive is how many of the nest's monsters are alive.
func (s *Slot) Alive() int { return s.alive }

// Hive is a hive at run time. Only a hive with a total cap (the row's col 3,
// dwOverwriteMaxTotalCount) changes anything: its nests run the hive-capped
// pass, AIHive_HatchPass_TotalCapped (0x55ec10), which stops once TotalCap of
// the hive's monsters are alive, and can pin one nest (+0x3c) -- the unique
// rotation's total-1 hive is that pass with a pinned nest (round 661).
type Hive struct {
	ID       int64
	TotalCap int
	// Pinned, when set, is the one nest the capped pass hatches from. A
	// total-1 hive pins nothing at build unless it has one nest (PinAtBuild,
	// CMainProcess::FUN_0055efe0) and re-pins at each death out of a full hive
	// (Repin, AI::CNest::FUN_0055eec0) -- the unique rotation (round 661).
	Pinned *Slot
	nests  []*Slot
	alive  int
	// built is whether the pass has made the hive's build-time pin.
	built bool
}

// Alive is how many of the hive's monsters are alive.
func (h *Hive) Alive() int { return h.alive }

// Nests is the hive's nests in the order they were added.
func (h *Hive) Nests() []*Slot { return h.nests }

// Hatcher makes the monster for one hatch: the slot, the class roll and the
// offset from the nest (HatchOffset). It answers the monster's id and
// whether it was made; failed reports a placement that failed as the
// engine's out-flag 1 does, which halves the nest's delay.
type Hatcher func(s *Slot, roll HatchRoll, dx, dz float64) (id int64, ok, failed bool)

// Scheduler is every nest's hatch pass, run from one goroutine (round 656's
// single respawn scheduler; no goroutine per nest). Pass and Died are the
// scheduler goroutine's; ArmParty is safe from any goroutine.
type Scheduler struct {
	mu    sync.Mutex
	dice  Dice
	hatch Hatcher
	// GiantRatio is GiantMonster_SpawnRatio (GiantMonsterSpawnRatio).
	GiantRatio int
	plain      []*Slot // nests in no capped hive, in the order added
	capped     []*Hive // hives with a total cap, in the order first seen
	byMonster  map[int64]*Slot
	// graveyard keeps the nests of the monsters that died in the last two
	// passes, so a kill's party arming (ArmParty) finds the nest even when
	// the pass drained the death first.
	graveyard [2]map[int64]*Slot
	hatched   int64
	deaths    int64
	// rotations is the re-pins since the last DrainRotations (round 661).
	rotations []Rotation
}

// Rotation is one re-arm of a capped hive at a death out of a full hive
// (Repin): the hive, the nest pinned (nil for a hive whose total is not 1,
// which re-arms its timers but pins nothing) and the pinned nest's wait.
type Rotation struct {
	Hive   *Hive
	Pinned *Slot
	// Roll is the nest index the dice picked (after the clamp), -1 for a
	// hive with no nests; for a total-1 hive it is the pinned nest's Index.
	Roll   int
	At     time.Time
	WaitMs int
}

// NewScheduler makes a scheduler drawing its dice from rng.
func NewScheduler(rng *rand.Rand, hatch Hatcher) *Scheduler {
	return NewSchedulerDice(RandDice(rng), hatch)
}

// NewSchedulerDice makes a scheduler throwing dice.
func NewSchedulerDice(dice Dice, hatch Hatcher) *Scheduler {
	return &Scheduler{dice: dice, hatch: hatch, GiantRatio: GiantMonsterSpawnRatio,
		byMonster: map[int64]*Slot{}, graveyard: [2]map[int64]*Slot{{}, {}}}
}

// Add registers a nest. A nest whose hive has a total cap runs that hive's
// capped pass; every other nest runs the plain pass.
func (s *Scheduler) Add(slot *Slot) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if h := slot.Hive; h != nil {
		slot.Index = len(h.nests)
		h.nests = append(h.nests, slot)
		if h.TotalCap > 0 {
			if len(h.nests) == 1 {
				s.capped = append(s.capped, h)
			}
			return
		}
	}
	s.plain = append(s.plain, slot)
}

// Nests is how many nests the scheduler runs.
func (s *Scheduler) Nests() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := len(s.plain)
	for _, h := range s.capped {
		n += len(h.nests)
	}
	return n
}

// Alive is how many of the scheduler's monsters are alive.
func (s *Scheduler) Alive() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.byMonster)
}

// Counts is how many monsters the scheduler has hatched and lost so far.
func (s *Scheduler) Counts() (hatched, deaths int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.hatched, s.deaths
}

// due is the slot's timer test, `stamp + base <= GetTickCount()`.
func (sl *Slot) due(now time.Time) bool {
	return !now.Before(sl.stamp.Add(time.Duration(sl.baseMs) * time.Millisecond))
}

// Pass is one hive pass at now over every nest, appending the new monsters'
// ids to dst. AIHive_HatchPass (0x55ea90) for a plain nest: it hatches one
// monster when
//
//	col17 == 0 && (col16 != 0 || budget > 0) && stamp + base <= now && alive < col14
//
// and AIHive_HatchPass_TotalCapped (0x55ec10) for a capped hive's nests: while
// fewer than the hive's cap are alive, the pinned nest alone or each nest in
// turn, when stamp + base <= now && alive < col14 (no col17/col16/budget
// test), stopping once the cap is reached. READ (round 239; the capped pass
// re-read in round 660). One monster per nest per pass.
func (s *Scheduler) Pass(now time.Time, dst []int64) []int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.graveyard[1], s.graveyard[0] = s.graveyard[0], s.graveyard[1]
	clear(s.graveyard[0])
	for _, sl := range s.plain {
		if !sl.Active || !(sl.Respawn || sl.Budget > 0) || !sl.due(now) || sl.alive >= sl.Cap {
			continue
		}
		if id, ok := s.hatchOne(sl, now); ok {
			dst = append(dst, id)
			if !sl.Respawn {
				sl.Budget--
			}
		}
	}
	for _, h := range s.capped {
		if !h.built {
			h.built = true
			if h.Pinned == nil {
				h.Pinned = PinAtBuild(s.dice, h)
			}
		}
		if h.alive >= h.TotalCap {
			continue
		}
		if h.Pinned != nil {
			if sl := h.Pinned; sl.due(now) && sl.alive < sl.Cap {
				if id, ok := s.hatchOne(sl, now); ok {
					dst = append(dst, id)
				}
			}
			continue
		}
		for _, sl := range h.nests {
			if !sl.due(now) || sl.alive >= sl.Cap {
				continue
			}
			if id, ok := s.hatchOne(sl, now); ok {
				dst = append(dst, id)
			}
			if h.alive >= h.TotalCap {
				break
			}
		}
	}
	return dst
}

// hatchOne is Nest_Hatch (0x5607b0) for one nest: the class roll, the spot,
// the monster, and on success the slot's alive count, stamp and a fresh
// delay (NestSlot_IncAlive, `*param_4 = GetTickCount()`, RollHatchDelay);
// on a failed placement the halved delay (NestSlot_HalveHatchDelay). A party
// hatch disarms the nest (`nest+0x30 = 0` when the class's high nibble is
// 0x10, 0x560d4b). The world's level clamp (ClampClassByLevel) runs on the
// class the monster is made with, after the nest decided -- the disarm reads
// the nest's own roll, as the engine's does.
func (s *Scheduler) hatchOne(sl *Slot, now time.Time) (int64, bool) {
	roll := RollClass(s.dice, sl.Input, s.GiantRatio)
	decided := roll.Class
	roll.Class = ClampClassByLevel(roll.Class, sl.Level)
	dx, dz := HatchOffset(s.dice, sl.GenerateRadius)
	id, ok, failed := s.hatch(sl, roll, dx, dz)
	if !ok {
		if failed {
			sl.baseMs = HalvedDelayMs(sl.baseMs)
		}
		return 0, false
	}
	sl.alive++
	if sl.Hive != nil {
		sl.Hive.alive++
	}
	sl.stamp = now
	sl.baseMs = HatchDelayMs(s.dice, sl.DelayMin, sl.DelayMax, 0)
	if decided.Party() {
		sl.Input.PartyArmed = false
	}
	s.byMonster[id] = sl
	s.hatched++
	return id, true
}

// Died is AI::CNest::vslot_004, the alive-count decrement, for monster id at
// now: the nest's timer is re-armed from this death only when the nest was
// full (`alive == col14`), so a full nest's first loss starts the wait and
// later ones do not. READ (round 239). A monster the scheduler did not hatch
// is ignored.
func (s *Scheduler) Died(id int64, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sl, ok := s.byMonster[id]
	if !ok {
		return
	}
	delete(s.byMonster, id)
	s.graveyard[0][id] = sl
	if sl.alive == sl.Cap {
		sl.stamp = now
	}
	if sl.alive > 0 {
		sl.alive--
	}
	if h := sl.Hive; h != nil {
		if h.TotalCap > 0 && h.alive == h.TotalCap {
			s.rotations = append(s.rotations, Repin(s.dice, h, now))
		}
		if h.alive > 0 {
			h.alive--
		}
	}
	s.deaths++
}

// DrainRotations appends the re-pins since the last call to dst and forgets
// them: the caller's log of the unique rotation (round 661).
func (s *Scheduler) DrainRotations(dst []Rotation) []Rotation {
	s.mu.Lock()
	defer s.mu.Unlock()
	dst = append(dst, s.rotations...)
	s.rotations = s.rotations[:0]
	return dst
}

// PinAtBuild is CMainProcess::FUN_0055efe0, the pin a total-1 hive makes when
// it is built (its caller 0x54bd7d stores the answer at hive+0x3c). READ from
// srv.asm 0x55efe0..0x55f077 (round 661's review; round 661 had misread it):
//
//	n == 1       -> nests[0]
//	n >= 2       -> k = abs(rand()) % n            ; 0x55f02f..0x55f041, the die is thrown
//	                eax = 0 ; k <= 0 -> NULL        ; 0x55f047..0x55f04b
//	                cmp eax,k; je FOUND             ; 0x55f04d, reached only on entry
//	                loop: add eax,1 ... cmp eax,k; jl loop   ; 0x55f051..0x55f05d re-enters PAST the compare
//	                -> NULL                         ; 0x55f05f
//
// so a hive of two or more nests pins NOTHING at build, whatever the die. The
// capped pass then hatches the first due nest in the hive's order (every
// stamp is 0 at build, 0x54bd2f): the unique's first appearance after a boot
// is nests[0]. A hive whose total is not 1, or with no nests, throws nothing.
func PinAtBuild(dice Dice, h *Hive) *Slot {
	n := len(h.nests)
	if h.TotalCap != 1 || n == 0 {
		return nil
	}
	if n == 1 {
		return h.nests[0]
	}
	_ = dice() % n // thrown and dropped: the loop never matches
	return nil
}

// Repin is AI::CNest::FUN_0055eec0, run at a death out of a capped hive
// (+0x30 == 1, which AIHive::Init sets for a non-zero col 3) that was full
// (`alive == row+0x08`, before its own decrement). READ from srv.asm
// 0x55eec0..0x55efce (round 661):
//
//	k = abs(rand()) % (n + 1)                 ; 0x55eeee..0x55eefd: div by n+1
//	if k >= n - 1: k = n - 1                  ; 0x55eeff..0x55ef0a: `cmp edx,eax; jb`
//	for i, nest in nests:                     ; the hive's nest list, in order
//	    if i == k and row+0x08 == 1:
//	        hive+0x3c = nest                  ; the pin, 0x55ef77
//	        RollHatchDelay(slot)              ; 0x55ef7a: a roll, overwritten below
//	    RearmHatchTimer(slot)                 ; 0x55ef82 -> 0x560e50: stamp = now,
//	                                          ; base = RollHatchDelay (the [col12, col13] window)
//
// So every nest of the hive waits a fresh uniform window from the death, and a
// total-1 hive moves its one monster to nests[k]. The pick is NOT uniform:
// rand() % (n + 1) has n + 1 outcomes and the clamp folds the last two onto
// nest n - 1, which is chosen twice as often as any other (2 in n + 1). Kept
// as read. Each roll throws a die only when the window's two ends differ
// (NestSlot_RollHatchDelay's `cmp esi,edi; ja`), so the dice are thrown in
// the engine's order: k, then per nest the pinned nest's discarded roll and
// its re-arm roll.
func Repin(dice Dice, h *Hive, now time.Time) Rotation {
	n := len(h.nests)
	rot := Rotation{Hive: h, At: now, Roll: -1}
	if n == 0 {
		return rot
	}
	k := dice() % (n + 1)
	if k >= n-1 {
		k = n - 1
	}
	rot.Roll = k
	for i, sl := range h.nests {
		if i == k && h.TotalCap == 1 {
			h.Pinned = sl
			rot.Pinned = sl
			HatchDelayMs(dice, sl.DelayMin, sl.DelayMax, 0) // 0x55ef7a: thrown, then overwritten
		}
		sl.stamp = now
		sl.baseMs = HatchDelayMs(dice, sl.DelayMin, sl.DelayMax, 0)
		if sl == rot.Pinned {
			rot.WaitMs = sl.baseMs
		}
	}
	return rot
}

// nestOfLocked is the nest monster id hatched from, alive or dead in the
// last two passes.
func (s *Scheduler) nestOfLocked(id int64) (*Slot, bool) {
	if sl, ok := s.byMonster[id]; ok {
		return sl, true
	}
	for _, g := range s.graveyard {
		if sl, ok := g[id]; ok {
			return sl, true
		}
	}
	return nil, false
}

// ArmParty arms the nest monster id hatched from for a party monster -- the
// death command's `nest+0x30 = 1` (FUN_00558f20) when its count of the
// killer's party members is above 1 (PartyArmCount). It reports whether a
// nest was armed.
func (s *Scheduler) ArmParty(id int64, members int) bool {
	if members < PartyArmCount {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sl, ok := s.nestOfLocked(id)
	if !ok {
		return false
	}
	sl.Input.PartyArmed = true
	return true
}
