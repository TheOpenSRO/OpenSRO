extends Node
class_name RetailLogin

## Logging in to a `type: legacy` server (round 788): the retail client's
## path, READ in RESEARCH section 1 of round 788 and
## docs/protocol/opcodes/gateway.md, "Logging in".
##
##   gateway  handshake, 0x2001, 0x6100 / 0xA100, 0x6101 / 0xA101 (the
##            server's name matched against the shard list for its id),
##            0x6102; 0x2322 image -> the image-code window -> 0x6323 ->
##            0xA323; 0xA102
##   agent    0xA102's token, host and port: the gateway connection closed,
##            the agent's opened; handshake, 0x2001 "AgentServer", 0x6103,
##            0xA103; then NetClient carries the lobby on it (the title
##            hands "logged_in"'s link to NetClient.attach_retail) for the
##            select screen.
##
## Each step's outcome goes to `step` for the title (Login.gd) to show:
##   {"kind": "connect_failed", "why"}       the gateway did not connect
##   {"kind": "login_failed", "ack"}         0xA102 refused (LoginAckNet.Ack)
##   {"kind": "captcha", "flag", "blob"}     0x2322: show the image window
##   {"kind": "captcha_failed", "max", "used"}, {"kind": "captcha_ok"}
##   {"kind": "agent_connect_failed", "why"} the agent did not connect
##   {"kind": "agent_failed", "code"}        0xA103 refused
##   {"kind": "logged_in", "link"}           on the agent (a RetailLink)
##   {"kind": "closed", "why"}               the server hung up (or an error)
## Entering the world on a legacy server is out of scope (round 788): the
## world protocol is not the original one yet.

signal step(ev: Dictionary)

## The trailer of 0x6103. READ: the MAC of the Ethernet adapter that holds
## the connection's local address (CNetEngine::vslot_034 0x4a1950,
## GetAdaptersInfo), all zeros when none matches; AgentServer stores it and
## checks nothing (0x402120). OURS: zeros -- Godot cannot read a MAC, and the
## original sends zeros itself when it finds none.
var agent_trailer := PackedByteArray([0, 0, 0, 0, 0, 0])
## The keep-alive on both links (RetailLink; off for the transcript tests).
var keep_alive := true
## The key exchange's private value for a test (-1 = random).
var private_x := -1

var _entry: ClientConfig.ServerEntry = null
var _info := {}
var _username := ""
var _password := ""
var _gateway: RetailLink = null
var _agent: RetailLink = null
var _done := false

## Starts at entry's gateway. `info` is RetailClientInfo.from_media's
## {content_id, version}; `shard` the chosen shard's name.
func start(entry: ClientConfig.ServerEntry, info: Dictionary, username: String, password: String, shard: String) -> void:
	_entry = entry
	_info = info
	_username = username
	_password = password
	_done = false
	var login := {"username": username, "password": password, "shard": shard}
	_gateway = RetailLink.new(entry.gateway_host, entry.gateway_port, func() -> RetailGatewayClient:
		var c := RetailGatewayClient.new(int(info["content_id"]), int(info["version"]), private_x)
		c.login = login.duplicate()
		return c)
	_gateway.keep_alive = keep_alive
	_gateway.start()
	print("RETAIL LOGIN: gateway %s:%d, shard '%s'" % [entry.gateway_host, entry.gateway_port, shard])

## Whether the gateway connection is up and a retry can go on it.
func can_resubmit() -> bool:
	return _gateway != null and _gateway.is_connected_now() and _gateway.conv.state == RetailGatewayClient.St.LOGIN_IDLE

## 0x6102 again on the open gateway connection (READ: retail retries on it).
func resubmit(username: String, password: String) -> void:
	_username = username
	_password = password
	_gateway.send(_gateway.conv.resubmit(username, password))

func submit_captcha(code: String) -> void:
	if _gateway != null:
		_gateway.send(_gateway.conv.submit_captcha(code))

func cancel() -> void:
	_done = true
	for l in [_gateway, _agent]:
		if l != null:
			(l as RetailLink).close()
	_gateway = null
	_agent = null

func _process(_delta: float) -> void:
	if _done:
		return
	if _gateway != null:
		for ev in _gateway.poll():
			_on_gateway(ev)
	if _agent != null and not _done:
		for ev in _agent.poll():
			_on_agent(ev)

func _emit(ev: Dictionary) -> void:
	step.emit(ev)

func _on_gateway(ev: Dictionary) -> void:
	match str(ev["kind"]):
		"connected":
			pass
		"login_ok":
			var a: LoginAckNet.Ack = ev["ack"]
			# READ: the client closes the gateway (net slot 0x5c) and connects
			# to the agent the reply names -- or, OURS, the config's `agent:`
			# entry when it has one (ClientConfig).
			_gateway.close()
			_gateway = null
			var host := a.agent_host
			var port := a.agent_port
			if _entry.agent_host != "":
				host = _entry.agent_host
				port = _entry.agent_port if _entry.agent_port > 0 else port
			print("RETAIL LOGIN: 0xA102 ok, token 0x%08x, agent %s:%d" % [a.token, host, port])
			var agent := {"token": a.token, "username": _username, "password": _password, "trailer": agent_trailer}
			var info := _info
			_agent = RetailLink.new(host, port, func() -> RetailGatewayClient:
				var c := RetailGatewayClient.new(int(info["content_id"]), int(info["version"]), private_x)
				c.agent = agent.duplicate()
				return c)
			_agent.keep_alive = keep_alive
			_agent.start()
		"closed":
			_gateway = null
			_emit(ev)
		_:
			_emit(ev)

func _on_agent(ev: Dictionary) -> void:
	match str(ev["kind"]):
		"connected":
			pass
		"connect_failed":
			_agent = null
			_emit({"kind": "agent_connect_failed", "why": ev["why"]})
		"agent_ok":
			print("RETAIL LOGIN: 0xA103 ok -- on the agent")
			_done = true
			var link := _agent
			_agent = null
			_emit({"kind": "logged_in", "link": link})
		"agent_failed":
			_agent.close()
			_agent = null
			_emit(ev)
		"closed":
			_agent = null
			_emit(ev)
		_:
			pass
