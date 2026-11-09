package session

// The game worlds' GM aid (round 869, OURS: a QA tool, not in the original's
// console -- the Forgotten World checklist's /fgw and /fgwtime, built for the
// foundation's live check):
//
//	/instance <world id | codename>   open a new layer of the world and enter it
//	/instance enter <world>.<layer>   enter an open layer
//	/instance leave                   back to the return point
//	/instance close                   close the layer the GM is in
//	/instance age [w.l] <duration>    move that (or the named) layer's clock (its warnings,
//	                                  end and empty close fire as if it passed)
//	/instance list                    the open layers
//
// The entry skips CanEnter (a GM's tool); everything after it is the
// ordinary entry (EnterInstance).

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
)

const instanceUsage = "usage: /instance <world id|code> | enter <world>.<layer> | leave | close | age <duration> | list"

// instanceCommand runs /instance for the GM on sess; ok is false for any
// other line.
func instanceCommand(ctx context.Context, sess *gateway.Session, line string) (gm.Result, bool) {
	f := strings.Fields(strings.TrimPrefix(strings.TrimSpace(line), "/"))
	if len(f) == 0 || !strings.EqualFold(f[0], "instance") {
		return gm.Result{}, false
	}
	m := GameWorlds()
	if m == nil {
		return gm.Result{Refused: true, Text: "no game-world data (-gameworld-dir)"}, true
	}
	if len(f) < 2 {
		return gm.Result{Refused: true, Text: instanceUsage}, true
	}
	cur := instanceOf(sessionHub(sess))
	switch strings.ToLower(f[1]) {
	case "list":
		var b strings.Builder
		for _, w := range m.List() {
			if w.Open() {
				continue
			}
			fmt.Fprintf(&b, "%s %s key %d members %d left %s; ", w.ID, w.Ref.Code, w.Key, len(w.Members()),
				w.Expires.Sub(w.Clock().Now()).Round(time.Second))
		}
		if b.Len() == 0 {
			return gm.Result{Text: "no open instance"}, true
		}
		return gm.Result{Text: strings.TrimSpace(b.String())}, true
	case "leave":
		if cur == nil {
			return gm.Result{Refused: true, Text: "not in an instance"}, true
		}
		if err := returnFromInstance(ctx, sess, cur.Hub, "gm instance leave"); err != nil {
			return gm.Result{Refused: true, Text: err.Error()}, true
		}
		return gm.Result{Text: "left " + cur.ID.String()}, true
	case "close":
		if cur == nil {
			return gm.Result{Refused: true, Text: "not in an instance"}, true
		}
		cur.CloseAsync(gameworld.CloseManual)
		return gm.Result{Text: "closing " + cur.ID.String()}, true
	case "age":
		// /instance age <duration> inside, /instance age <world>.<layer>
		// <duration> from anywhere (an empty layer's close).
		if len(f) == 4 {
			var wid, lid int
			if _, err := fmt.Sscanf(f[2], "%d.%d", &wid, &lid); err == nil {
				cur = m.Get(registry.InstanceID{World: uint16(wid), Layer: uint16(lid)})
				f = []string{f[0], f[1], f[3]}
			}
		}
		if cur == nil || cur.Open() || len(f) != 3 {
			return gm.Result{Refused: true, Text: "usage: /instance age [<world>.<layer>] <duration, e.g. 55m>"}, true
		}
		d, err := time.ParseDuration(f[2])
		if err != nil || d <= 0 {
			return gm.Result{Refused: true, Text: "usage: /instance age <duration, e.g. 55m>"}, true
		}
		cur.AgeAsync(d)
		return gm.Result{Text: fmt.Sprintf("%s aged %s", cur.ID, d)}, true
	case "enter":
		if len(f) != 3 {
			return gm.Result{Refused: true, Text: instanceUsage}, true
		}
		parts := strings.SplitN(f[2], ".", 2)
		wid, err1 := strconv.Atoi(parts[0])
		var lid int
		var err2 error = fmt.Errorf("no layer")
		if len(parts) == 2 {
			lid, err2 = strconv.Atoi(parts[1])
		}
		if err1 != nil || err2 != nil {
			return gm.Result{Refused: true, Text: instanceUsage}, true
		}
		w := m.Get(registry.InstanceID{World: uint16(wid), Layer: uint16(lid)})
		if w == nil || w.Open() {
			return gm.Result{Refused: true, Text: "no such open instance"}, true
		}
		if err := EnterInstance(ctx, sess, w, "gm instance enter"); err != nil {
			return gm.Result{Refused: true, Text: err.Error()}, true
		}
		return gm.Result{Text: "entered " + w.ID.String()}, true
	}
	ref := m.Ref().WorldByCode(f[1])
	if ref == nil {
		if id, err := strconv.Atoi(f[1]); err == nil {
			ref = m.Ref().World(uint16(id))
		}
	}
	if ref == nil || !ref.Instanced() {
		return gm.Result{Refused: true, Text: "not an instanced world: " + f[1]}, true
	}
	owner := int64(0)
	if h := sessionHub(sess); h != nil {
		if e, ok := h.EntityBySession(sess.ID()); ok {
			owner = e.CharacterID
		}
	}
	w, err := m.Open(ctx, ref.ID, owner, 0)
	if err != nil {
		return gm.Result{Refused: true, Text: "open: " + err.Error()}, true
	}
	if err := EnterInstance(ctx, sess, w, "gm instance"); err != nil {
		return gm.Result{Refused: true, Text: err.Error()}, true
	}
	return gm.Result{Text: fmt.Sprintf("opened and entered %s %s (key %d, ends %s)", w.ID, ref.Code, w.Key,
		w.Expires.Format("15:04:05"))}, true
}
