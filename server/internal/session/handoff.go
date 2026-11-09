package session

// Moving a character to another process (round 869 lane W2, OURS,
// docs/protocol/game_worlds.md 12.2): the hand-off. It looks to the player and
// to everyone around exactly like a warp between two worlds of one process
// (warpAcross): the watchers where it left drop it, the client gets the
// ordinary zone change and its loading screen, and its 0x3012 releases it
// where it lands.
//
// The source (handOff): the character's session is marked and asked to end
// (gateway.Session.RequestEnd); the disconnect bookkeeping runs in its
// hand-off form -- the hub, the view, the per-character runtimes are let go
// as at a logout, but nobody hears it went offline, its party keeps it, its
// account stays logged in -- and its last step sends the front the re-route
// with the hand-off: the carried runtime (buffs, cooldowns, MP), the return
// point and the destination.
//
// The target (AdoptHandler): the front opens a stream whose hello carries the
// hand-off; the session is authenticated as the account, the character is
// read from the shared database, its carried runtime put back, and it enters
// the destination held, as a warp files it.
//
// A recovery (the front lost a host's stream: the host died) is an adoption
// at the character's return point on the open world's host.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
	"github.com/TheOpenSRO/OpenSRO/server/internal/relay"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Handoff is what a character carries to another process.
type Handoff struct {
	From     string        `json:"from"`
	Account  int64         `json:"account"`
	Username string        `json:"username"`
	Char     int64         `json:"char"`
	Dest     HandoffDest   `json:"dest"`
	Carried  CarriedState  `json:"carried"`
	Return   *HandoffPlace `json:"return,omitempty"`
	Heading  float64       `json:"heading"`
	// Sent is when the source sent it (the entry time's start).
	Sent time.Time `json:"sent"`
}

// HandoffDest is where the character lands: a world unit (the open world is
// world 1 layer 1) and the place in it.
type HandoffDest struct {
	World uint16       `json:"world"`
	Layer uint16       `json:"layer"`
	Key   uint32       `json:"key"`
	Place HandoffPlace `json:"place"`
	Via   string       `json:"via"`
}

// HandoffPlace is a zone label, its bucket and frame and a point.
type HandoffPlace struct {
	Zone   string  `json:"zone"`
	Bucket string  `json:"bucket"`
	Frame  string  `json:"frame"`
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Z      float64 `json:"z"`
}

func placeFrom(zone, bucket, frame string, pos world.Position) HandoffPlace {
	return HandoffPlace{Zone: zone, Bucket: bucket, Frame: frame, X: pos.X, Y: pos.Y, Z: pos.Z}
}

func (p HandoffPlace) pos() world.Position { return world.Position{X: p.X, Y: p.Y, Z: p.Z} }

func (p HandoffPlace) returnPoint() returnPoint {
	return returnPoint{zone: p.Zone, bucket: p.Bucket, frame: p.Frame, pos: p.pos()}
}

func handoffPlaceOf(rp returnPoint) *HandoffPlace {
	p := placeFrom(rp.zone, rp.bucket, rp.frame, rp.pos)
	return &p
}

const handoffKey = "session.handoff"

type pendingHandoff struct {
	h    Handoff
	host registry.Host
}

// Handoff counters (the load test's and the metrics' source).
var handoffsOut, handoffsIn, recoveries atomic.Int64

// HandoffCounts is the hand-offs sent and taken and the recoveries.
func HandoffCounts() (out, in, recovered int64) {
	return handoffsOut.Load(), handoffsIn.Load(), recoveries.Load()
}

// HandingOff reports a session whose character is moving to another process
// (its disconnect is the hand-off's, not a logout).
func HandingOff(sess *gateway.Session) bool {
	if sess == nil {
		return false
	}
	_, ok := sess.Get(handoffKey)
	return ok
}

func handoffPending(sess *gateway.Session) *pendingHandoff {
	v, ok := sess.Get(handoffKey)
	if !ok {
		return nil
	}
	p, _ := v.(*pendingHandoff)
	return p
}

// ErrNotRelayed is a move to another process of a session no front relays
// (a client connected straight to a world host cannot be moved).
var ErrNotRelayed = errors.New("session: the client is not on a front; it cannot move to another process")

// handOff starts the move of sess's character to host, landing at dest.
func handOff(sess *gateway.Session, host registry.Host, dest HandoffDest) error {
	cs := clusterRT.Load()
	if cs == nil {
		return errors.New("session: no cluster")
	}
	if !relay.Relayed(sess) {
		return ErrNotRelayed
	}
	if HandingOff(sess) {
		return errors.New("session: already moving")
	}
	acc, _ := AuthenticatedAccountID(sess)
	user, _ := AuthenticatedUsername(sess)
	h := Handoff{From: cs.node.ID(), Account: acc, Username: user, Dest: dest, Sent: time.Now()}
	if hub := sessionHub(sess); hub != nil {
		if e, ok := hub.EntityBySession(sess.ID()); ok {
			h.Char = e.CharacterID
		}
	}
	sess.Set(handoffKey, &pendingHandoff{h: h, host: host})
	sess.RequestEnd()
	slog.Info("hand-off started", "character_id", h.Char, "to", host.ID, "world", fmt.Sprintf("%d.%d", dest.World, dest.Layer),
		"zone", dest.Place.Zone, "via", dest.Via)
	return nil
}

// HandoffPrepare is the hand-off's first disconnect step: the carried
// runtime, the heading and the return point are taken before the rest of the
// bookkeeping lets them go.
func HandoffPrepare(sess *gateway.Session) {
	p := handoffPending(sess)
	if p == nil {
		return
	}
	if hub := sessionHub(sess); hub != nil {
		if e, ok := hub.EntityBySession(sess.ID()); ok {
			p.h.Char = e.CharacterID
			p.h.Heading = e.Heading
		}
	}
	if p.h.Char == 0 {
		return
	}
	p.h.Carried = SnapshotCarried(p.h.Char)
	if v, ok := instanceReturns.Load(p.h.Char); ok {
		p.h.Return = handoffPlaceOf(v.(returnPoint))
	}
}

// HandoffSend is the hand-off's last disconnect step: the re-route to the
// front.
func HandoffSend(sess *gateway.Session) {
	p := handoffPending(sess)
	if p == nil || p.h.Char == 0 {
		return
	}
	b, err := json.Marshal(p.h)
	if err != nil {
		return
	}
	if err := relay.SendReroute(sess, relay.Reroute{Host: p.host.ID, Addr: p.host.Addr, Handoff: b}); err != nil {
		slog.Warn("hand-off: the re-route was not sent", "character_id", p.h.Char, "to", p.host.ID, "err", err)
		return
	}
	handoffsOut.Add(1)
	metrics.Teleport("handoff out")
}

// ---- the source's targets ----

// clusterHomeHost is the open world's host when it is another process.
func clusterHomeHost() (registry.Host, bool) {
	cs := clusterRT.Load()
	if cs == nil || cs.home {
		return registry.Host{}, false
	}
	return cs.node.Home()
}

// openWorldElsewhere reports a warp target that is the open world's hub on a
// process that does not run the open world (its own open world unit is
// never played in): the move is a hand-off to the open world's host.
func openWorldElsewhere(to *world.Hub) bool {
	if clusterHome() {
		return false
	}
	w := unitOf(to)
	return w != nil && w.Open()
}

// clusterSetReturn keeps a character's return point in the registry.
func clusterSetReturn(ctx context.Context, char int64, rp returnPoint) {
	cs := clusterRT.Load()
	if cs == nil {
		return
	}
	if err := cs.node.Registry().SetReturn(ctx, char, registry.Return{Zone: rp.zone, Bucket: rp.bucket, Frame: rp.frame,
		X: rp.pos.X, Y: rp.pos.Y, Z: rp.pos.Z}); err != nil {
		slog.Warn("return point not kept in the registry", "character_id", char, "err", err)
	}
}

// clusterClearReturn drops it at the exit.
func clusterClearReturn(ctx context.Context, char int64) {
	if cs := clusterRT.Load(); cs != nil {
		cs.node.Registry().ClearReturn(ctx, char)
	}
}

// handOffToOpenWorld is warpAcross into the open world from a process that
// does not run it: a hand-off to the open world's host.
func handOffToOpenWorld(sess *gateway.Session, zone, bucket string, pos world.Position, frame, via string) (bool, error) {
	home, ok := clusterHomeHost()
	if !ok {
		return false, sess.Send(&proto.Packet{Opcode: OpChangeZoneResult,
			Data: (&ChangeZoneResult{Reason: "the open world is not reachable"}).Encode()})
	}
	err := handOff(sess, home, HandoffDest{World: gameworld.OpenWorldID, Layer: gameworld.OpenLayer,
		Place: placeFrom(zone, bucket, frame, pos), Via: via})
	return err == nil, err
}

// handOffToInstance is EnterInstance's move into a layer another host runs
// (a proxy): the place is the one EnterInstance picked.
func handOffToInstance(sess *gateway.Session, w *gameworld.World, zone, bucket string, pos world.Position, frame, via string) error {
	cs := clusterRT.Load()
	if cs == nil {
		return errors.New("session: no cluster")
	}
	host, ok := cs.node.Host(w.HostID())
	if !ok || !cs.node.Live(host) {
		cs.node.RefreshHosts(context.Background())
		if host, ok = cs.node.Host(w.HostID()); !ok || host.State == registry.HostDead {
			return fmt.Errorf("session: the host %s of %s is gone", w.HostID(), w.ID)
		}
	}
	return handOff(sess, host, HandoffDest{World: w.ID.World, Layer: w.ID.Layer, Key: w.Key,
		Place: placeFrom(zone, bucket, frame, pos), Via: via})
}

// ---- the target ----

// loginOnline is the login service's logged-in table (SetLoginOnline): an
// adopted session holds its account there as a login would.
var loginOnline atomic.Pointer[OnlineAccounts]

// SetLoginOnline names the logged-in table (cmd/server).
func SetLoginOnline(o *OnlineAccounts) { loginOnline.Store(o) }

// AdoptHandler takes the hand-offs and recoveries a front's stream opens
// with (relay.OpAdopt).
func AdoptHandler(chars character.Store, eq equipment.Store, hub *world.Hub, zerk *berserk.Tracker) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != relay.OpAdopt {
			return nil
		}
		var hello relay.Hello
		if err := json.Unmarshal(p.Data, &hello); err != nil {
			return err
		}
		if hello.Recover != nil {
			return adoptRecover(ctx, sess, *hello.Recover, chars, eq, hub, zerk)
		}
		var h Handoff
		if err := json.Unmarshal(hello.Handoff, &h); err != nil {
			return fmt.Errorf("hand-off: %w", err)
		}
		return adopt(ctx, sess, h, chars, eq, hub, zerk)
	}
}

// adoptAccount authenticates sess as the hand-off's account and holds it in
// the logged-in table.
func adoptAccount(sess *gateway.Session, account int64, username string) {
	authenticate(sess, account, username)
	if o := loginOnline.Load(); o != nil {
		o.Rebind(account, sess)
	}
}

// adoptCharacter reads the hand-off's character and checks it is the
// account's.
func adoptCharacter(ctx context.Context, chars character.Store, account, char int64) (*character.Character, error) {
	if chars == nil {
		return nil, errors.New("no character store")
	}
	c, err := chars.GetByID(ctx, char)
	if err != nil || c == nil {
		return nil, fmt.Errorf("character %d: %v", char, err)
	}
	if c.AccountID != account {
		return nil, fmt.Errorf("character %d is not account %d's", char, account)
	}
	return c, nil
}

func adopt(ctx context.Context, sess *gateway.Session, h Handoff, chars character.Store, eq equipment.Store, def *world.Hub, zerk *berserk.Tracker) error {
	adoptAccount(sess, h.Account, h.Username)
	owned, err := adoptCharacter(ctx, chars, h.Account, h.Char)
	if err != nil {
		return fmt.Errorf("hand-off refused: %w", err)
	}
	RestoreCarried(owned.ID, h.Carried)
	if h.Return != nil {
		instanceReturns.Store(owned.ID, h.Return.returnPoint())
	}
	var to *world.Hub
	if h.Dest.World == gameworld.OpenWorldID {
		to = openHub(def)
	} else if m := GameWorlds(); m != nil {
		if w := m.Get(registry.InstanceID{World: h.Dest.World, Layer: h.Dest.Layer}); w != nil && w.Key == h.Dest.Key && !w.Closed() {
			to = w.Hub
		}
	}
	place, via := h.Dest.Place, h.Dest.Via
	if to == nil {
		// The layer closed while the character was on its way: to its
		// return point (READ s:0x5f80b0: a closing layer sends everyone
		// there), on this process when it runs the open world, else on
		// the one that does.
		rp, ok := returnPlaceOf(ctx, chars, owned.ID)
		if !ok {
			return errors.New("hand-off: the layer is gone and there is no return point")
		}
		place, via = *handoffPlaceOf(rp), "instance gone"
		if !clusterHome() {
			if err := enterAdopted(ctx, sess, owned, chars, eq, openHub(def), zerk, place, h.Heading, via, h.Sent, true); err != nil {
				return err
			}
			_, err := handOffToOpenWorld(sess, place.Zone, place.Bucket, place.pos(), place.Frame, via)
			return err
		}
		to = openHub(def)
	}
	handoffsIn.Add(1)
	return enterAdopted(ctx, sess, owned, chars, eq, to, zerk, place, h.Heading, via, h.Sent, false)
}

// enterAdopted puts owned into hub at place as a warp's arrival: held until
// its client's 0x3012 when the guard is on, the ordinary zone change sent.
// quiet files it without telling anyone (a pass-through on the way on).
func enterAdopted(ctx context.Context, sess *gateway.Session, owned *character.Character, chars character.Store, eq equipment.Store,
	hub *world.Hub, zerk *berserk.Tracker, place HandoffPlace, heading float64, via string, sent time.Time, quiet bool) error {
	if hub == nil {
		return errors.New("hand-off: no world to enter")
	}
	pos := place.pos()
	vd := viewDeps{ctx: ctx, hub: hub, eq: eq, chars: chars, zerk: zerk}
	guard := arrivalGuardOn.Load()
	forgetNPCWindow(sess.ID())
	closePlayerView(owned.ID, sess, vd)
	invalidateLook(owned.ID)
	titleAtEntry(ctx, chars, owned.ID)
	if guard {
		hub.EnterHeld(sess, owned.ID, owned.Name, owned.Level, place.Bucket, pos)
	} else {
		hub.Enter(sess, owned.ID, owned.Name, owned.Level, place.Bucket, pos)
	}
	noteArrivalLanding(owned.ID, place.Zone, pos)
	noteWalkInArrival(hub, owned.ID, place.Bucket, pos)
	hub.SetHeading(sess, heading)
	rememberPlace(sess, place.Zone, place.Frame, time.Now())
	motions.enter(owned.ID, time.Now())
	restoreSkillJobs(ctx, owned.ID, time.Now())
	arrived, inWorld := hub.EntityBySession(sess.ID())
	if quiet {
		return nil
	}
	if inWorld {
		savePosition(chars, sess, arrived)
	}
	if guard && inWorld {
		arrived.Session = sess
		holdArrival(vd, arrived, via, nil)
	}
	data, _ := (&ChangeZoneResult{OK: true, Zone: place.Zone, X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
		FrameRegion: place.Frame}).EncodeFitting()
	if err := sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: data}); err != nil {
		return err
	}
	if w := instanceOf(hub); w != nil {
		w.Enter(owned.ID, owned.Level)
	}
	if inWorld {
		arrived.Session = sess
		clusterArrived(sess, arrived)
		if !guard {
			arrivePlayer(vd, arrived)
		}
		sendOwnBuffs(arrived, time.Now())
	}
	metrics.Teleport("handoff in")
	username, _ := AuthenticatedUsername(sess)
	took := time.Duration(0)
	if !sent.IsZero() {
		took = time.Since(sent)
		observeHandoff(took)
	}
	slog.Info("hand-off in", "character", owned.Name, "character_id", owned.ID, "account", username, "via", via,
		"zone", place.Zone, "world", worldLabel(hub), "took", took.Round(time.Microsecond))
	return nil
}

func worldLabel(hub *world.Hub) string {
	if w := unitOf(hub); w != nil {
		return w.ID.String()
	}
	return "1.1"
}

// adoptRecover is a recovery: the front lost the character's host (it died);
// the character is put at its return point in the open world.
func adoptRecover(ctx context.Context, sess *gateway.Session, b relay.Bind, chars character.Store, eq equipment.Store, def *world.Hub, zerk *berserk.Tracker) error {
	adoptAccount(sess, b.Account, b.Username)
	owned, err := adoptCharacter(ctx, chars, b.Account, b.Char)
	if err != nil {
		return fmt.Errorf("recovery refused: %w", err)
	}
	// A character still in the world here (the stream broke, the host did
	// not die) goes back where it stood; otherwise its return point.
	place, ok := recoverPlace(ctx, chars, owned)
	if !ok {
		return errors.New("recovery: no return point")
	}
	if cs := clusterRT.Load(); cs != nil {
		cs.node.Registry().ClearReturn(ctx, owned.ID)
	}
	instanceReturns.Delete(owned.ID)
	recoveries.Add(1)
	return enterAdopted(ctx, sess, owned, chars, eq, openHub(def), zerk, place, 0, "recover", time.Time{}, false)
}

// recoverPlace is where a recovered character lands: the return point the
// registry kept at its instance entry, else its saved place, else its start.
func recoverPlace(ctx context.Context, chars character.Store, c *character.Character) (HandoffPlace, bool) {
	if cs := clusterRT.Load(); cs != nil {
		if r, ok, _ := cs.node.Registry().ReturnOf(ctx, c.ID); ok {
			return HandoffPlace{Zone: r.Zone, Bucket: r.Bucket, Frame: r.Frame, X: r.X, Y: r.Y, Z: r.Z}, true
		}
	}
	rp, ok := returnPlaceOf(ctx, chars, c.ID)
	if !ok {
		return HandoffPlace{}, false
	}
	return *handoffPlaceOf(rp), true
}

// ---- the instance placement ----

// clusterPlacer places instances through the node (gameworld.Placer).
type clusterPlacer struct{ version string }

// NewClusterPlacer is the Placer for the world manager (cmd/server).
func NewClusterPlacer(version string) gameworld.Placer { return clusterPlacer{version: version} }

func (p clusterPlacer) Version() string { return p.version }

func (p clusterPlacer) Attach(ctx context.Context, host string, in registry.Instance) error {
	cs := clusterRT.Load()
	if cs == nil {
		return errors.New("no cluster")
	}
	return cs.node.Call(ctx, host, kindAttach, in, nil)
}

// onAttach builds a layer another process placed here.
func onAttach(ctx context.Context, m clusterMsg) (any, error) {
	var in registry.Instance
	if err := m.Decode(&in); err != nil {
		return nil, err
	}
	mgr := GameWorlds()
	if mgr == nil {
		return nil, errors.New("no game worlds here")
	}
	draining := false
	if cs := clusterRT.Load(); cs != nil {
		draining = cs.node.Draining()
	}
	_, err := mgr.Attach(ctx, in, draining)
	return nil, err
}

// ---- the accounts ----

type accountBody struct {
	Account int64 `json:"a"`
}

// clusterAccountEnded is a session's end on this process: on a process that
// is not the open world's, the open world's host (where logins are held) is
// told the account logged out.
func clusterAccountEnded(sess *gateway.Session) {
	cs := clusterRT.Load()
	if cs == nil || cs.home || HandingOff(sess) {
		return
	}
	acc, ok := AuthenticatedAccountID(sess)
	if !ok {
		return
	}
	if home, ok := cs.node.Home(); ok {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		cs.node.Send(ctx, home.ID, kindAccount, accountBody{Account: acc})
		cancel()
	}
}

func onAccountGone(_ context.Context, m clusterMsg) (any, error) {
	var b accountBody
	if err := m.Decode(&b); err != nil {
		return nil, err
	}
	if o := loginOnline.Load(); o != nil {
		o.ReleaseRemote(b.Account)
	}
	return nil, nil
}

// SessionEndedInCluster is the login step of a session's end with several
// processes (cmd/server's OnDisconnect): a hand-off keeps the account logged
// in (held by a remote session on the open world's host), a logout on
// another process frees it there.
func SessionEndedInCluster(sess *gateway.Session, release func(*gateway.Session)) {
	if !clusterOn() {
		release(sess)
		return
	}
	if HandingOff(sess) {
		if p := handoffPending(sess); p != nil && clusterHome() {
			if o := loginOnline.Load(); o != nil {
				if acc, ok := AuthenticatedAccountID(sess); ok {
					o.Rebind(acc, remoteAccountSession(p.host.ID, p.h.Char))
				}
			}
			return
		}
		release(sess)
		return
	}
	relay.SendUnbind(sess)
	release(sess)
	clusterAccountEnded(sess)
}

// remoteAccountSession is the remote session holding an account's login on
// the open world's host while its character plays on host.
func remoteAccountSession(host string, char int64) *gateway.Session {
	cs := clusterRT.Load()
	return cs.stubFor(registry.Character{ID: char, Host: host})
}
