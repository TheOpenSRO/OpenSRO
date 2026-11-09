package session

// The session layer's part of several processes (round 869 lane W2, OURS,
// docs/protocol/game_worlds.md 12): with a cluster node installed
// (SetCluster, -role world), what must reach a character wherever it plays
// -- a whisper, a party, guild, academy or union line or update, a friend's
// push, a notice, a GM look-up -- finds it in the presence directory when it
// is on another process and is delivered there over the bus, through a
// remote session that stands for it here (gateway.NewRemoteSession). Without
// a node (the default, -role all) every helper below answers exactly as
// before: the local hubs only.

import (
	"bytes"
	"context"
	"encoding/json"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cluster"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
	"github.com/TheOpenSRO/OpenSRO/server/internal/relay"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The message kinds the session layer serves.
const (
	kindDeliver   = "session.deliver"
	kindKick      = "session.kick"
	kindAttach    = "gameworld.attach"
	kindParty     = "party.snapshot"
	kindAccount   = "account.gone"
	kindBroadcast = "session.everyone"
)

// clusterState is the installed node and its delivery queues.
type clusterState struct {
	node *cluster.Node
	// home: this process runs the open world (logins, the social
	// services' authority).
	home bool

	mu      sync.Mutex
	outbox  map[string]*outbox
	stubs   map[int64]*gateway.Session
	stubIDs atomic.Uint64

	// presence is the ordered queue of this process's arrivals and
	// departures (a relog's offline must not overtake its online).
	presence chan func()
}

var clusterRT atomic.Pointer[clusterState]

// ClusterNode is the installed node, nil in one process.
func ClusterNode() *cluster.Node {
	if cs := clusterRT.Load(); cs != nil {
		return cs.node
	}
	return nil
}

// clusterOn reports several processes.
func clusterOn() bool { return clusterRT.Load() != nil }

// clusterHome reports a process running the open world: always in one
// process.
func clusterHome() bool {
	cs := clusterRT.Load()
	return cs == nil || cs.home
}

// SetCluster installs the node (cmd/server -role world, before the node
// starts): the session layer's message kinds are registered on it.
func SetCluster(n *cluster.Node, home bool) {
	cs := &clusterState{node: n, home: home, outbox: map[string]*outbox{}, stubs: map[int64]*gateway.Session{},
		presence: make(chan func(), 4096)}
	cs.stubIDs.Store(1 << 62)
	n.Handle(kindDeliver, cs.onDeliver)
	n.Handle(kindKick, cs.onKick)
	n.Handle(kindAttach, onAttach)
	n.Handle(kindParty, onPartySnapshot)
	n.Handle(kindAccount, onAccountGone)
	n.Handle(kindBroadcast, cs.onEveryone)
	n.Handle(kindCrest, onCrest)
	n.Handle(kindFriendAnswer, onFriendAnswer)
	n.Handle(kindRestrictions, onRestrictions)
	n.Handle(kindGuildPlate, onGuildPlate)
	go func() {
		for f := range cs.presence {
			f()
		}
	}()
	clusterRT.Store(cs)
}

// ---- delivery ----

// wireFrame is one packet on the bus.
type wireFrame struct {
	Op   uint16 `json:"o"`
	Data []byte `json:"d"`
}

// delivery is frames for characters on one host.
type delivery struct {
	Chars  []int64     `json:"c"`
	Frames []wireFrame `json:"f"`
}

type deliverBody struct {
	Items []delivery `json:"i"`
}

func framesOf(ps []*proto.Packet) []wireFrame {
	out := make([]wireFrame, len(ps))
	for i, p := range ps {
		out[i] = wireFrame{Op: p.Opcode, Data: p.Data}
	}
	return out
}

func sameFrames(a, b []wireFrame) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Op != b[i].Op || !bytes.Equal(a[i].Data, b[i].Data) {
			return false
		}
	}
	return true
}

// outbox batches the deliveries to one host: one bus message carries
// everything queued since the last, and the same frames for several
// characters travel once.
type outbox struct {
	cs   *clusterState
	host string
	mu   sync.Mutex
	q    []delivery
	wake chan struct{}
}

// outboxBatch is how long an outbox waits to batch (OURS).
const outboxBatch = time.Millisecond

func (cs *clusterState) outboxFor(host string) *outbox {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	o := cs.outbox[host]
	if o == nil {
		o = &outbox{cs: cs, host: host, wake: make(chan struct{}, 1)}
		cs.outbox[host] = o
		go o.run()
	}
	return o
}

func (o *outbox) add(char int64, fs []wireFrame) {
	o.mu.Lock()
	if n := len(o.q); n > 0 && sameFrames(o.q[n-1].Frames, fs) {
		o.q[n-1].Chars = append(o.q[n-1].Chars, char)
	} else {
		o.q = append(o.q, delivery{Chars: []int64{char}, Frames: fs})
	}
	o.mu.Unlock()
	select {
	case o.wake <- struct{}{}:
	default:
	}
}

func (o *outbox) run() {
	for range o.wake {
		time.Sleep(outboxBatch)
		o.mu.Lock()
		q := o.q
		o.q = nil
		o.mu.Unlock()
		if len(q) == 0 {
			continue
		}
		// Keep each bus message well under a frame's worth of JSON.
		for len(q) > 0 {
			n, size := 0, 0
			for n < len(q) && (n == 0 || size < 24<<10) {
				for _, f := range q[n].Frames {
					size += len(f.Data)*4/3 + 16
				}
				size += 12 * len(q[n].Chars)
				n++
			}
			body := deliverBody{Items: q[:n]}
			q = q[n:]
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			if err := o.cs.node.Send(ctx, o.host, kindDeliver, body); err != nil {
				o.cs.node.Logger().Warn("cluster: a delivery was not sent", "host", o.host, "err", err)
			}
			cancel()
		}
	}
}

// localSession is the session of character id on this process.
func localSession(id int64) (*gateway.Session, bool) {
	h, ok := world.Locate(id)
	if !ok {
		return nil, false
	}
	e, ok := h.EntityByCharacterID(id)
	if !ok || e.Session == nil || e.Session.Remote() {
		return nil, false
	}
	return e.Session, true
}

func (cs *clusterState) onDeliver(_ context.Context, m cluster.Msg) (any, error) {
	var b deliverBody
	if err := m.Decode(&b); err != nil {
		return nil, err
	}
	for _, it := range b.Items {
		ps := make([]*proto.Packet, len(it.Frames))
		for i, f := range it.Frames {
			ps[i] = &proto.Packet{Opcode: f.Op, Data: f.Data}
		}
		for _, id := range it.Chars {
			if s, ok := localSession(id); ok {
				_ = s.SendBatch(ps...)
				continue
			}
			// Moved on meanwhile (a hand-off): one more hop, never back.
			if c, ok := cs.node.Lookup(id); ok && c.Host != cs.node.ID() && c.Host != m.From {
				cs.outboxFor(c.Host).add(id, it.Frames)
			}
		}
	}
	return nil, nil
}

type kickBody struct {
	Char int64 `json:"c"`
}

func (cs *clusterState) onKick(_ context.Context, m cluster.Msg) (any, error) {
	var b kickBody
	if err := m.Decode(&b); err != nil {
		return nil, err
	}
	if s, ok := localSession(b.Char); ok {
		s.Close()
	}
	return nil, nil
}

// stubSink is a remote session's sink: the character's host's outbox.
type stubSink struct {
	cs   *clusterState
	char int64
	host string
}

func (s *stubSink) SendRemote(ps []*proto.Packet) error {
	s.cs.outboxFor(s.host).add(s.char, framesOf(ps))
	return nil
}

func (s *stubSink) CloseRemote() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return s.cs.node.Send(ctx, s.host, kindKick, kickBody{Char: s.char})
}

// stubFor is the remote session standing for c (on another host): one per
// character and host, so a session-keyed map sees one id while it stays
// there.
func (cs *clusterState) stubFor(c registry.Character) *gateway.Session {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	if s := cs.stubs[c.ID]; s != nil {
		if sk, ok := stubSinkOf(s); ok && sk.host == c.Host {
			return s
		}
	}
	s := gateway.NewRemoteSession(cs.stubIDs.Add(1), &stubSink{cs: cs, char: c.ID, host: c.Host},
		gateway.RelayAddr{Text: "host:" + c.Host})
	stubSinks.Store(s, &stubSink{cs: cs, char: c.ID, host: c.Host})
	cs.stubs[c.ID] = s
	return s
}

var stubSinks sync.Map // *gateway.Session -> *stubSink

func stubSinkOf(s *gateway.Session) (*stubSink, bool) {
	v, ok := stubSinks.Load(s)
	if !ok {
		return nil, false
	}
	return v.(*stubSink), true
}

// forgetStub drops c's stub (it left the cluster or came here).
func (cs *clusterState) forgetStub(id int64) {
	cs.mu.Lock()
	if s := cs.stubs[id]; s != nil {
		stubSinks.Delete(s)
		delete(cs.stubs, id)
	}
	cs.mu.Unlock()
}

// ---- finding a character anywhere ----

// remoteEntity is character id when it plays on another process: an entity
// with its name and level and a remote session (no position: a caller that
// needs one acts only on local characters).
func remoteEntity(id int64) (world.Entity, bool) {
	cs := clusterRT.Load()
	if cs == nil {
		return world.Entity{}, false
	}
	c, ok := cs.node.Lookup(id)
	if !ok || c.Host == cs.node.ID() {
		return world.Entity{}, false
	}
	return world.Entity{Session: cs.stubFor(c), CharacterID: c.ID, Name: c.Name, Level: c.Level}, true
}

// reachOf is the character to send to: in hub, in any world of this process
// (the presence index), else on another process. For what must reach a
// character wherever it is; never for what acts on its body.
func reachOf(hub *world.Hub, id int64) (world.Entity, bool) {
	if hub != nil {
		if e, ok := hub.EntityByCharacterID(id); ok {
			return e, true
		}
	}
	if h, ok := world.Locate(id); ok && h != hub {
		if e, ok := h.EntityByCharacterID(id); ok {
			return e, true
		}
	}
	return remoteEntity(id)
}

// remoteByName is the character named name on another process.
func remoteByName(name string) (world.Entity, bool) {
	cs := clusterRT.Load()
	if cs == nil {
		return world.Entity{}, false
	}
	c, ok := cs.node.LookupName(name)
	if !ok || c.Host == cs.node.ID() {
		return world.Entity{}, false
	}
	return world.Entity{Session: cs.stubFor(c), CharacterID: c.ID, Name: c.Name, Level: c.Level}, true
}

// remoteEveryone is every character on the other processes.
func remoteEveryone() []world.Entity {
	cs := clusterRT.Load()
	if cs == nil {
		return nil
	}
	var out []world.Entity
	for _, c := range cs.node.Everyone() {
		if c.Host != cs.node.ID() {
			out = append(out, world.Entity{Session: cs.stubFor(c), CharacterID: c.ID, Name: c.Name, Level: c.Level})
		}
	}
	return out
}

// everyoneBody is a packet for every character of every other process.
type everyoneBody struct {
	Frames []wireFrame `json:"f"`
	Skip   int64       `json:"s,omitempty"`
}

// sendEverywhere sends ps to every character on the other processes, one
// bus message for all (a world chat line, a notice).
func sendEverywhere(skip int64, ps ...*proto.Packet) {
	cs := clusterRT.Load()
	if cs == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cs.node.Broadcast(ctx, kindBroadcast, everyoneBody{Frames: framesOf(ps), Skip: skip})
}

func (cs *clusterState) onEveryone(_ context.Context, m cluster.Msg) (any, error) {
	if m.From == cs.node.ID() {
		return nil, nil
	}
	var b everyoneBody
	if err := m.Decode(&b); err != nil {
		return nil, err
	}
	ps := make([]*proto.Packet, len(b.Frames))
	for i, f := range b.Frames {
		ps[i] = &proto.Packet{Opcode: f.Op, Data: f.Data}
	}
	for _, e := range localEveryone() {
		if e.CharacterID != b.Skip && e.Session != nil {
			_ = e.Session.SendBatch(ps...)
		}
	}
	return nil, nil
}

// localEveryone is every character of every world of this process.
func localEveryone() []world.Entity {
	var out []world.Entity
	if m := GameWorlds(); m != nil {
		for _, w := range m.List() {
			out = append(out, w.Hub.AllEntities()...)
		}
		return out
	}
	if h := clusterOpenHub.Load(); h != nil {
		return h.AllEntities()
	}
	return nil
}

// clusterOpenHub is the open world's hub without a world manager.
var clusterOpenHub atomic.Pointer[world.Hub]

// SetClusterOpenHub records the open world's hub (cmd/server).
func SetClusterOpenHub(h *world.Hub) { clusterOpenHub.Store(h) }

// ---- presence ----

// clusterArrived files a character arriving on this process (a login, a
// hand-off in) in the directory, and tells its front who is on the stream.
func clusterArrived(sess *gateway.Session, e world.Entity) {
	cs := clusterRT.Load()
	if cs == nil {
		return
	}
	acc, _ := AuthenticatedAccountID(sess)
	user, _ := AuthenticatedUsername(sess)
	relay.SendBind(sess, relay.Bind{Account: acc, Username: user, Char: e.CharacterID})
	cs.forgetStub(e.CharacterID)
	c := registry.Character{ID: e.CharacterID, Name: e.Name, Level: e.Level, Account: acc, Username: user}
	select {
	case cs.presence <- func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		cs.node.Online(ctx, c)
		cancel()
	}:
	default:
	}
	partyMemberArrived(e)
}

// clusterLeft files a character leaving this process.
func clusterLeft(id int64) {
	cs := clusterRT.Load()
	if cs == nil {
		return
	}
	select {
	case cs.presence <- func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		cs.node.Offline(ctx, id)
		cancel()
	}:
	default:
	}
}

// ClusterPresenceChanged is the node's OnPresence: a character arriving on
// another process has its stub there (its party members' sessions follow
// it).
func ClusterPresenceChanged(c registry.Character, online bool) {
	cs := clusterRT.Load()
	if cs == nil {
		return
	}
	if c.Host == cs.node.ID() {
		return
	}
	if !online {
		cs.forgetStub(c.ID)
		return
	}
	partyMemberMoved(c.ID, cs.stubFor(c))
}

// marshal is json.Marshal for the bodies (never fails for them).
func marshal(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// clusterMsg is a bus message.
type clusterMsg = cluster.Msg

// observeHandoff records a hand-off's entry time.
func observeHandoff(d time.Duration) { metrics.Handoff(d) }
