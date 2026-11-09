package session

// Game worlds in the session layer (round 869, docs/protocol/game_worlds.md
// 14 items 2-4): every handler acts in the world the session's character is
// in. The handler factories still take the open world's hubs; each handler
// resolves its caller's world at its start (world.Hub.For, monstersFor,
// groundFor -- inserted at the top of every handler and of every function
// taking a session and a hub), so in the open world nothing changes and in
// an instance everything a handler touches is that instance's.
//
// What crosses worlds on purpose goes through world.FindCharacter (the
// presence index): a whisper, a party line, a per-character timer's
// broadcast.

import (
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// gameWorlds is the process's world manager (SetGameWorlds), nil when the
// server runs without game-world data: then there is only the open world,
// as before round 869.
var gameWorlds atomic.Pointer[gameworld.Manager]

// SetGameWorlds installs the manager (cmd/server, before the gateway serves).
func SetGameWorlds(m *gameworld.Manager) { gameWorlds.Store(m) }

// GameWorlds is the installed manager, nil for none.
func GameWorlds() *gameworld.Manager { return gameWorlds.Load() }

// unitOf is the world unit owning hub, nil for a bare hub (the open world
// without a manager, a test's hub).
func unitOf(hub *world.Hub) *gameworld.World { return gameworld.Of(hub) }

// instanceOf is the instance unit owning hub: nil for the open world and for
// a bare hub.
func instanceOf(hub *world.Hub) *gameworld.World {
	if w := gameworld.Of(hub); w != nil && !w.Open() {
		return w
	}
	return nil
}

// sessionHub is the hub sess's character is in, nil when it has none.
func sessionHub(sess *gateway.Session) *world.Hub {
	if sess == nil {
		return nil
	}
	h, _ := sess.Place().(*world.Hub)
	return h
}

// monstersFor is the monster hub of sess's world: an instance's own, else
// def (the open world's).
func monstersFor(sess *gateway.Session, def *combat.Hub) *combat.Hub {
	if def == nil {
		return nil
	}
	if w := instanceOf(sessionHub(sess)); w != nil && w.Monsters != nil {
		return w.Monsters
	}
	return def
}

// groundFor is the ground-item hub of sess's world.
func groundFor(sess *gateway.Session, def *grounditem.Hub) *grounditem.Hub {
	if def == nil {
		return nil
	}
	if w := instanceOf(sessionHub(sess)); w != nil && w.Ground != nil {
		return w.Ground
	}
	return def
}

// findByNameAnywhere is FindByName in def, then in every live world (a
// whisper, a friend request, a GM's look-up: what must reach a character
// wherever it is; with several processes the registry's presence and the bus,
// game_worlds.md 12.3).
func findByNameAnywhere(def *world.Hub, name string) (world.Entity, bool) {
	if def != nil {
		if e, ok := def.FindByName(name); ok {
			return e, true
		}
	}
	if m := GameWorlds(); m != nil {
		for _, w := range m.List() {
			if w.Hub == def {
				continue
			}
			if e, ok := w.Hub.FindByName(name); ok {
				return e, true
			}
		}
	}
	return world.Entity{}, false
}

// allEntitiesAnywhere is every character of def and of every other live
// world (a broadcast to everyone: the world chat, the game clock, a crest).
func allEntitiesAnywhere(def *world.Hub) []world.Entity {
	var out []world.Entity
	if def != nil {
		out = def.AllEntities()
	}
	if m := GameWorlds(); m != nil {
		for _, w := range m.List() {
			if w.Hub != def {
				out = append(out, w.Hub.AllEntities()...)
			}
		}
	}
	return out
}

// hubOfChar is the hub holding character id, else def: for what must reach
// a character wherever it is (its own timers' broadcasts, a party line).
func hubOfChar(def *world.Hub, characterID int64) *world.Hub {
	if def == nil {
		return nil
	}
	{
		if _, ok := def.EntityByCharacterID(characterID); ok {
			return def
		}
	}
	return world.HubOf(def, characterID)
}

// findByNameCluster is findByNameAnywhere, then the characters of the other
// processes (round 869 lane W2: a whisper, a friend request, a GM's kick --
// the answer reaches the character there through its remote session).
func findByNameCluster(def *world.Hub, name string) (world.Entity, bool) {
	if e, ok := findByNameAnywhere(def, name); ok {
		return e, true
	}
	return remoteByName(name)
}

// everyoneCluster is allEntitiesAnywhere and every character of the other
// processes (a GM's look-up by account or by name without case).
func everyoneCluster(def *world.Hub) []world.Entity {
	return append(allEntitiesAnywhere(def), remoteEveryone()...)
}
