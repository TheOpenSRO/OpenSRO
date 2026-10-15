package retailsrv

import (
	"github.com/OpenSRO/OpenSRO/server/internal/retailgw"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
)

// The retail login's opcodes (READ: RESEARCH section 1, gateway.md).
const (
	OpIdentity        = retailgw.OpIdentity         // 0x2001 both ways
	OpKeepAlive       = uint16(0x2002)              // client -> server
	OpPatchRequest    = retailgw.OpPatchRequest     // 0x6100
	OpPatchReply      = retailgw.OpPatchReply       // 0xA100, massive
	OpShardListReq    = retailgw.OpShardListRequest // 0x6101
	OpShardList       = retailgw.OpShardListReply   // 0xA101
	OpLogin           = session.OpGatewayLogin      // 0x6102
	OpLoginReply      = session.OpGatewayLoginAck   // 0xA102
	OpAgentLogin      = uint16(0x6103)
	OpAgentLoginReply = uint16(0xA103)
	OpNoticeRequest   = uint16(0x6104)
	OpNoticeReply     = uint16(0xA104)
	OpFarmRequest     = uint16(0x6106)
	OpFarmReply       = uint16(0xA106)
	OpLobby           = session.OpLobby       // 0x7007
	OpLobbyResult     = session.OpLobbyResult // 0xB007
	OpStart           = session.OpStart       // 0x7001
	OpStartResult     = session.OpStartResult // 0xB001
)

// Module names (READ: retailgw.GatewayModule, "GatewayServer"; the agent's
// "AgentServer" is the identity the client answers with 0x6103,
// CClientProcess::vslot_014 0x4ceb36).
const (
	GatewayModule = retailgw.GatewayModule
	AgentModule   = "AgentServer"
)
