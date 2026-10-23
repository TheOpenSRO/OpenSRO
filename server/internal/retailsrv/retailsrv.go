// Package retailsrv is OpenSRO's retail front door (round 788): a gateway
// listener and an agent listener that speak the original wire
// (retailgw.ServerCodec), so the ORIGINAL client (sro_client.exe, vSRO
// 1.188) logs in to this server and reaches its character list. The login
// itself is session.LoginService's and the lobby session.LobbyHandler's, run
// unchanged on the retail framing. The world is not offered: Start is
// refused. docs/protocol/opcodes/gateway.md, "OpenSRO's retail listeners
// (round 788)".
package retailsrv

import (
	"context"
	"encoding/hex"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/retailgw"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// Config is both listeners' settings.
type Config struct {
	// ContentID and Version are what 0x6100 must carry (MEASURED on the
	// render box's vSRO 1.188 archives: content id 22, version 1000; the
	// operator sets them for other clients).
	ContentID byte
	Version   uint32
	// ShardID and ShardName are the one shard 0xA101 lists, FarmName its farm
	// (OURS: one farm, one shard -- this server).
	ShardID   uint16
	ShardName string
	FarmName  string
	// AgentHost and AgentPort are what 0xA102 names: the agent listener as
	// the client must reach it.
	AgentHost string
	AgentPort uint16
	// Status is the shard's population and inspection flag.
	Status func() session.ServerStatus
	// Login decides each login (the same service every front door asks).
	Login *session.LoginService
	// Lobby answers the agent's 0x7007 (session.LobbyHandler).
	Lobby gateway.Handler
	// Tokens queue the gateway's admitted logins for the agent.
	Tokens *Tokens
	Logger *slog.Logger
	// Fixed replaces the handshake's random values (tests).
	Fixed *retailgw.Fixed
}

func (c *Config) logger() *slog.Logger {
	if c.Logger != nil {
		return c.Logger
	}
	return slog.Default()
}

// secret reports the opcodes whose payload carries a password: the packet
// log writes only their size.
func secret(op uint16) bool {
	return op == OpLogin || op == OpAgentLogin
}

// packetLog is the listener's packet log (OURS): every message after the
// handshake, each way, with its bytes, at Info -- except the keep-alive and
// the server list the client asks for every 5 s on its title screen, at
// Debug. A 0x6102 / 0x6103 body is withheld: it carries the password.
func packetLog(c *Config, listener string) func(fromServer bool, op uint16, payload []byte) {
	return func(fromServer bool, op uint16, payload []byte) {
		dir := "recv"
		if fromServer {
			dir = "send"
		}
		data := hex.EncodeToString(payload)
		if secret(op) {
			data = "(withheld: carries a password)"
		}
		lvl := slog.LevelInfo
		if op == OpKeepAlive || op == OpShardListReq || op == OpShardList {
			lvl = slog.LevelDebug
		}
		c.logger().Log(context.Background(), lvl, "retail "+listener+" packet", "dir", dir, "opcode", hexOp(op), "size", len(payload), "data", data)
	}
}

func hexOp(op uint16) string {
	const digits = "0123456789abcdef"
	return "0x" + string([]byte{digits[op>>12], digits[op>>8&15], digits[op>>4&15], digits[op&15]})
}
