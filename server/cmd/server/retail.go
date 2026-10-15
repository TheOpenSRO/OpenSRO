package main

// The retail front door (round 788): a gateway and an agent listener that
// speak the original wire, so the original client logs in as far as its
// character list (internal/retailsrv; deploy/README.md, "The original
// client"). Both are off unless -retail-gateway-addr is set.

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"strconv"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/retailsrv"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
)

// retailFlags are the retail listeners' settings.
type retailFlags struct {
	gatewayAddr, agentAddr, agentHost *string
	shardID, contentID, version       *int
	shardName                         *string
}

// Defaults (OURS unless noted).
const (
	// defaultRetailAgentAddr: the agent's port when only the gateway is set.
	defaultRetailAgentAddr = ":15781"
	// defaultRetailShardID: the id of our one shard in 0xA101; the client
	// sends it back in 0x6102.
	defaultRetailShardID = 1
	// defaultRetailContentID and defaultRetailVersion: MEASURED, the render
	// box's vSRO 1.188 archives (DIVISIONINFO.TXT's first byte 22; SV.T 1000,
	// gateway.md).
	defaultRetailContentID = 22
	defaultRetailVersion   = 1000
)

func registerRetailFlags() *retailFlags {
	envInt := func(name string, def int) int {
		if v := os.Getenv(name); v != "" {
			if n, err := strconv.Atoi(v); err == nil {
				return n
			}
			fmt.Fprintf(os.Stderr, "%s is not a number; using %d\n", name, def)
		}
		return def
	}
	envStr := func(name, def string) string {
		if v := os.Getenv(name); v != "" {
			return v
		}
		return def
	}
	return &retailFlags{
		gatewayAddr: flag.String("retail-gateway-addr", os.Getenv("OPENSRO_RETAIL_GATEWAY_ADDR"),
			"listen address of the retail GATEWAY, the original client's first connection, e.g. :15780 "+
				"(env OPENSRO_RETAIL_GATEWAY_ADDR). Empty (the default): no retail listeners. See deploy/README.md, \"The original client\"."),
		agentAddr: flag.String("retail-agent-addr", envStr("OPENSRO_RETAIL_AGENT_ADDR", defaultRetailAgentAddr),
			"listen address of the retail AGENT, where the gateway sends a logged-in original client (env OPENSRO_RETAIL_AGENT_ADDR)"),
		agentHost: flag.String("retail-agent-public-host", os.Getenv("OPENSRO_RETAIL_AGENT_PUBLIC_HOST"),
			"the host the gateway names for the agent in its login reply: an address the CLIENT can reach "+
				"(env OPENSRO_RETAIL_AGENT_PUBLIC_HOST). Empty: the agent address's own host, else 127.0.0.1"),
		shardID: flag.Int("retail-shard-id", envInt("OPENSRO_RETAIL_SHARD_ID", defaultRetailShardID),
			"the shard id the retail gateway lists for this server (1-65535; env OPENSRO_RETAIL_SHARD_ID)"),
		shardName: flag.String("retail-shard-name", envStr("OPENSRO_RETAIL_SHARD_NAME", "OpenSRO"),
			"the shard name the retail gateway lists for this server (env OPENSRO_RETAIL_SHARD_NAME)"),
		contentID: flag.Int("retail-content-id", envInt("OPENSRO_RETAIL_CONTENT_ID", defaultRetailContentID),
			"the content id the original client must send (the first byte of its DIVISIONINFO.TXT; vSRO 1.188: 22; env OPENSRO_RETAIL_CONTENT_ID)"),
		version: flag.Int("retail-version", envInt("OPENSRO_RETAIL_VERSION", defaultRetailVersion),
			"the client version the retail gateway accepts (the number in the client's SV.T; vSRO 1.188: 1000; env OPENSRO_RETAIL_VERSION)"),
	}
}

// retailDeps is what the retail listeners share with the main server.
type retailDeps struct {
	login        *session.LoginService
	lobby        gateway.Handler
	status       func() session.ServerStatus
	onDisconnect func(*gateway.Session)
}

// startRetail starts both retail listeners when -retail-gateway-addr is set;
// it returns at once (each listener runs until ctx ends) or exits on a bad
// setting.
func startRetail(ctx context.Context, f *retailFlags, d retailDeps, logger *slog.Logger) {
	if *f.gatewayAddr == "" {
		return
	}
	fail := func(msg string, args ...any) {
		logger.Error(msg, args...)
		os.Exit(1)
	}
	if *f.shardID < 1 || *f.shardID > 0xffff {
		fail("-retail-shard-id must be 1-65535", "given", *f.shardID)
	}
	if *f.contentID < 0 || *f.contentID > 0xff {
		fail("-retail-content-id must be 0-255", "given", *f.contentID)
	}
	if *f.version < 0 {
		fail("-retail-version must not be negative", "given", *f.version)
	}
	host, portStr, err := net.SplitHostPort(*f.agentAddr)
	if err != nil {
		fail("-retail-agent-addr", "err", err)
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 1 || port > 0xffff {
		fail("-retail-agent-addr needs a port 1-65535", "given", *f.agentAddr)
	}
	public := *f.agentHost
	if public == "" {
		public = host
	}
	if public == "" || public == "0.0.0.0" || public == "::" {
		public = "127.0.0.1"
		logger.Warn("retail: -retail-agent-public-host not set: the gateway sends clients to 127.0.0.1, which only a client on this machine can reach")
	}
	cfg := &retailsrv.Config{
		ContentID: byte(*f.contentID), Version: uint32(*f.version),
		ShardID: uint16(*f.shardID), ShardName: *f.shardName, FarmName: *f.shardName,
		AgentHost: public, AgentPort: uint16(port),
		Status: d.status, Login: d.login, Lobby: d.lobby,
		Tokens: &retailsrv.Tokens{}, Logger: logger,
	}
	gw := retailsrv.GatewayServer(cfg, *f.gatewayAddr)
	ag := retailsrv.AgentServer(cfg, *f.agentAddr, d.onDisconnect)
	logger.Info("retail listeners", "gateway", *f.gatewayAddr, "agent", *f.agentAddr, "agent_public", fmt.Sprintf("%s:%d", public, port),
		"shard_id", *f.shardID, "shard_name", *f.shardName, "content_id", *f.contentID, "version", *f.version)
	for _, s := range []*gateway.Server{gw, ag} {
		go func(s *gateway.Server) {
			if err := s.ListenAndServe(ctx); err != nil {
				fail("retail listener exited", "addr", s.Addr, "error", err)
			}
		}(s)
	}
}
