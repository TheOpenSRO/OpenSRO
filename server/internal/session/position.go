package session

// A character logs back in where it left off (round 573), behind cmd/server's
// -persist-position (SRREVAMP_PERSIST_POSITION), OFF by default.
//
// GROUNDED: the engine keeps a character's position on its row. `_CHAR`
// declares LatestRegion, PosX, PosY and PosZ, and CharData_BindDBColumns binds
// them to charData +0x94, +0x98, +0x9c and +0xa0 (docs/protocol/
// db_bind_offsets.tsv; persistence.ColumnOffsets). The round-549 revive note in
// deadstate.go reads the same four fields as the return point of last resort.
//
// OWN DESIGN, disclosed -- none of this was read from the retail server:
//
//   - The SHAPE (character.Character.Zone): the zone label, the frame region
//     "x/y" the coordinates are relative to and a world point in that frame,
//     not a region id and a region-local point.
//   - WHEN it is saved: on a disconnect (WorldDisconnectHandler,
//     from the entity hub.Leave returns), on each successful zone change, at
//     most once every positionSaveInterval from the move handler, and for
//     every character still in the world when the server stops
//     (SaveAllPositions). The retail save cadence was not read.
//   - The frame RULE (inFrame): a position saved in one frame and read under
//     another is the same place named in the new frame -- worldmap.Rebase,
//     the region-delta form of worldmap.ToWorld -- at spawnPos's height,
//     because the client's heights are anchored per frame (round 570's
//     _frame_anchor_height) and the server knows no ground.
//
// What the client does with a restored position is its own (round 573's
// World3D._load_initial_region_neighborhood): a result with Restored set keeps
// the position instead of being moved on to the zone's landing spot.

import (
	"context"
	"log"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/world"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// persistPosition is cmd/server's -persist-position, OFF by default: set on the
// boot goroutine before the gateway serves, read by every world handler (an
// atomic, like singleFrame). Off, nothing is saved or restored and the wire is
// what it was.
var persistPosition atomic.Bool

// SetPersistPosition turns the saved position on or off. cmd/server calls it
// once at boot, before the gateway serves.
func SetPersistPosition(on bool) { persistPosition.Store(on) }

// positionSaveInterval is how often, at most, a moving character's position is
// written from the move handler, so a crash or a stop the gateway does not
// report as a disconnect loses little of a walk. OWN DESIGN, disclosed: the
// retail server's save cadence was not read. 30 s keeps the store to one write
// per moving character per half minute.
const positionSaveInterval = 30 * time.Second

// positionSaveTimeout bounds one position write, so a stalled database cannot
// hold a disconnect or a move open. OWN DESIGN, disclosed.
const positionSaveTimeout = 5 * time.Second

// placeKey is the session value holding the place the session's character was
// last given (a place): the hub keeps only the bucket, which under
// -single-frame is worldmap.WorldBucket for every framed label, so the label
// and the frame the client was told are remembered here.
const placeKey = "session.world.place"

// placeSavedKey holds when the session's position was last saved, apart from
// the place itself (round 665's review, M1): the move handler's periodic save
// used to read the place and write it back with a new time, so a warp run off
// the session goroutine (returnAfterKill) that set a new place between the two
// had its label overwritten with the old one. The save now writes only this.
const placeSavedKey = "session.world.placeSaved"

// place is the zone label and FrameRegion a session's character entered or
// last changed zone with, and when its position was last saved.
type place struct {
	zone, frame string
	saved       time.Time
}

// rememberPlace records the label and frame sess's character was just given --
// an enter or a zone change, whose arrival position is what a save would
// write, so the clock starts there too.
func rememberPlace(sess *gateway.Session, zone, frame string, now time.Time) {
	sess.Set(placeSavedKey, now)
	sess.Set(placeKey, place{zone: zone, frame: frame, saved: now})
}

func placeOf(sess *gateway.Session) (place, bool) {
	v, ok := sess.Get(placeKey)
	if !ok {
		return place{}, false
	}
	p, ok := v.(place)
	return p, ok
}

// savePosition writes e's position under the place sess's character was
// given, with the flag on. A failure is logged, never returned: a move, a
// zone change or a disconnect must not fail over it.
func savePosition(chars character.Store, sess *gateway.Session, e world.Entity) bool {
	if chars == nil || !persistPosition.Load() {
		return false
	}
	p, ok := placeOf(sess)
	if !ok {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), positionSaveTimeout)
	defer cancel()
	if err := chars.SavePosition(ctx, e.CharacterID, p.zone, p.frame, e.Pos.X, e.Pos.Y, e.Pos.Z); err != nil {
		log.Printf("session: saving %q's position: %v", e.Name, err)
		return false
	}
	// The heading goes with it (round 637's review follow-up; OURS, as
	// character.HeadingStore says), for a store that keeps one.
	if hs, ok := chars.(character.HeadingStore); ok {
		if err := hs.SetHeading(ctx, e.CharacterID, e.Heading); err != nil {
			log.Printf("session: saving %q's heading: %v", e.Name, err)
		}
	}
	return true
}

// restoredHeading is the heading a character re-enters facing: the saved one
// when its position was restored (restoredArrival) and the store keeps one,
// else 0.
func restoredHeading(ctx context.Context, chars character.Store, characterID int64, restored bool) float64 {
	if !restored {
		return 0
	}
	hs, ok := chars.(character.HeadingStore)
	if !ok {
		return 0
	}
	h, err := hs.Heading(ctx, characterID)
	if err != nil {
		log.Printf("session: reading character %d's heading: %v", characterID, err)
		return 0
	}
	return h
}

// savePositionEvery is the move handler's save: at most once every
// positionSaveInterval per session (the place's clock).
func savePositionEvery(chars character.Store, sess *gateway.Session, e world.Entity, now time.Time) {
	if chars == nil || !persistPosition.Load() {
		return
	}
	p, ok := placeOf(sess)
	if !ok {
		return
	}
	last := p.saved
	if v, ok := sess.Get(placeSavedKey); ok {
		if t, ok := v.(time.Time); ok && t.After(last) {
			last = t
		}
	}
	if now.Sub(last) < positionSaveInterval {
		return
	}
	if savePosition(chars, sess, e) {
		sess.Set(placeSavedKey, now)
	}
}

// SaveAllPositions saves the position of every character still in hub. The
// gateway runs no OnDisconnect for sessions still open when it stops (see
// cmd/server's guild-points flush), so without this a server stop -- every
// deploy -- would keep only the last periodic save. cmd/server calls it once
// the listener has stopped. A no-op with -persist-position off.
func SaveAllPositions(hub *world.Hub, chars character.Store) {
	if !persistPosition.Load() {
		return
	}
	for _, e := range hub.AllEntities() {
		// Dead, at its return point (round 665, savedPlace).
		savePosition(chars, e.Session, savedPlace(chars, e.Session, e))
	}
}

// restoredArrival is where c re-enters the world when its position was saved
// (-persist-position on, c.Zone set): the saved label's bucket and frame as
// arrival gives them today, and the saved point named in that frame (inFrame).
// ok is false with the flag off, with nothing saved, and when the saved frame
// cannot be named in today's -- the character then enters at the spawn.
func restoredArrival(c *character.Character) (zone, bucket string, pos world.Position, frame string, ok bool) {
	if !persistPosition.Load() || c.Zone == "" {
		return "", "", world.Position{}, "", false
	}
	bucket, _, frame, _ = arrival(c.Zone)
	pos, ok = inFrame(world.Position{X: c.PosX, Y: c.PosY, Z: c.PosZ}, c.Frame, frame)
	if !ok {
		return "", "", world.Position{}, "", false
	}
	return c.Zone, bucket, pos, frame, true
}

// inFrame names pos, saved in the frame centred on region `from`, in the frame
// centred on `to` (both "x/y", or "" for a label with no frame). The same
// frame keeps pos exactly. Two different regions: worldmap.Rebase moves x and
// z by the from-region's middle as the to-frame sees it -- region y drives
// world X, region x drives world Z, Z mirrored (AGENTS.md; worldmap's
// measured columns) -- so a point saved under 98/157 and read under 97/168
// moves by ToWorld(98, 157, 960, 960, 97, 168) = (-21120, -1920). Its height
// becomes spawnPos's: the client anchors each frame's heights on that frame's
// own region (round 570), so a height from another frame names no ground, and
// the client lifts the player onto the terrain as it does every arrival. ok is
// false when either frame is "" or not a region and they differ: there is no
// frame to convert through.
func inFrame(pos world.Position, from, to string) (world.Position, bool) {
	if from == to {
		return pos, true
	}
	fx, fy, okFrom := worldmap.ParseRegionLabel(from)
	tx, ty, okTo := worldmap.ParseRegionLabel(to)
	if !okFrom || !okTo {
		return world.Position{}, false
	}
	x, z := worldmap.Rebase(pos.X, pos.Z, fx, fy, tx, ty)
	return world.Position{X: x, Y: spawnPos.Y, Z: z}, true
}
