extends RefCounted
class_name GuildStorageState

## The guild storage's side of NetClient (round 844, lane H): it registers
## for 0xB250 / 0xB251 / 0xB252 and the list's 0x3253 / 0x3255 / 0x3254
## (GuildStorageNet has the READ wire), assembles the list and sends the
## requests. The 0x7034 replies reach it through NetClient's 0xB034 routing
## (on_move).

## 0xB250's answer (GuildStorageNet.decode_open_result).
signal opened(result: Dictionary)
## 0xB251's answer.
signal closed(result: Dictionary)
## A whole list arrived: the size, the gold, {slot: ItemInstance}.
signal listed(capacity: int, gold: int, slots: Dictionary)
## 0xB252's refusal (its {1} is said by `listed`).
signal list_refused(code: int)
## A 0x7034 of the storage's types answered (GuildStorageNet.decode_move).
signal moved(result: Dictionary)

## Sends (opcode, payload); NetClient binds it.
var send: Callable
## The NPC the storage was opened at (the requests carry it).
var npc := 0
## The last list, kept so the window draws it when built after it.
var capacity := 0
var gold := 0
var slots := {}
var _body := PackedByteArray()
var _gold_begin := 0

func register_with(nc) -> void:
	nc.register_handler(GuildStorageNet.OP_OPEN_RESULT, func(data: PackedByteArray) -> void:
		var r := GuildStorageNet.decode_open_result(data)
		if not r.is_empty():
			opened.emit(r))
	nc.register_handler(GuildStorageNet.OP_CLOSE_RESULT, func(data: PackedByteArray) -> void:
		var r := GuildStorageNet.decode_result(data)
		if not r.is_empty():
			closed.emit(r))
	nc.register_handler(GuildStorageNet.OP_LIST_RESULT, func(data: PackedByteArray) -> void:
		var r := GuildStorageNet.decode_result(data)
		if not r.is_empty() and not bool(r.ok):
			list_refused.emit(int(r.code)))
	nc.register_handler(GuildStorageNet.OP_BEGIN, func(data: PackedByteArray) -> void: begin(data))
	nc.register_handler(GuildStorageNet.OP_DATA, func(data: PackedByteArray) -> void: _body.append_array(data))
	nc.register_handler(GuildStorageNet.OP_END, func(_data: PackedByteArray) -> void: end())

## 0x3253: the buffer reset and the gold (c:0x88d1d0).
func begin(data: PackedByteArray) -> void:
	_body = PackedByteArray()
	_gold_begin = data.decode_u64(0) if data.size() >= 8 else 0

## 0x3254: the bytes parsed (c:0x88d240).
func end() -> void:
	var d := GuildStorageNet.decode_list(_body)
	_body = PackedByteArray()
	if d.is_empty():
		push_warning("GuildStorageState: the list did not parse")
		return
	capacity = int(d.capacity)
	gold = _gold_begin
	slots = d.slots
	listed.emit(capacity, gold, slots)

## A 0x7034 answer of the storage's (NetClient's routing): the kept list
## follows it as the client's own copy does (c:0x87ba20), then `moved`.
func on_move(r: Dictionary) -> void:
	if r.is_empty():
		return
	if bool(r.get("ok", false)):
		apply(r)
	moved.emit(r)

## Applies a success to the kept list: gold in / out moves the storage's
## gold (c:0x87cb1d, c:0x87d5ed), a deposit leaves its slot to the next list
## (the bag's copy names the item; OURS: the window asks the bag), a
## withdraw empties its slot, a move inside moves, merges or swaps.
func apply(r: Dictionary) -> void:
	match int(r.type):
		GuildStorageNet.TYPE_GOLD_IN:
			gold += int(r.amount)
		GuildStorageNet.TYPE_GOLD_OUT:
			gold = maxi(0, gold - int(r.amount))
		GuildStorageNet.TYPE_WITHDRAW:
			slots.erase(int(r.src))
		GuildStorageNet.TYPE_INSIDE:
			var a: ItemInstance = slots.get(int(r.src))
			var b: ItemInstance = slots.get(int(r.dst))
			if a == null:
				return
			if b == null:
				slots.erase(int(r.src))
				a.slot = int(r.dst)
				slots[int(r.dst)] = a
			elif b.ref_item_id == a.ref_item_id and not a.is_equipment and b.count < _max_stack(b.ref_item_id):
				# A merge (CGStorage::CountCanBeMerged above 0): the count is
				# what crossed.
				var n := mini(int(r.count), a.count)
				b.count += n
				a.count -= n
				if a.count <= 0:
					slots.erase(int(r.src))
			else:
				a.slot = int(r.dst)
				b.slot = int(r.src)
				slots[int(r.dst)] = a
				slots[int(r.src)] = b

## An item's stack size (ref id -> int), the item table's; 1 when unbound.
var max_stack: Callable

func _max_stack(ref_id: int) -> int:
	return int(max_stack.call(ref_id)) if max_stack.is_valid() else 1

## A deposit's item enters the kept list (the bag's copy of it).
func put(slot: int, it: ItemInstance) -> void:
	if it != null:
		it.slot = slot
		slots[slot] = it

func reset() -> void:
	npc = 0
	capacity = 0
	gold = 0
	slots = {}
	_body = PackedByteArray()

func _send(op: int, payload: PackedByteArray) -> void:
	if send.is_valid():
		send.call(op, payload)

func request_open(npc_uid: int) -> void:
	npc = npc_uid
	_send(GuildStorageNet.OP_OPEN, GuildStorageNet.encode_npc(npc_uid))

func request_list() -> void:
	_send(GuildStorageNet.OP_LIST, GuildStorageNet.encode_npc(npc))

func request_close() -> void:
	_send(GuildStorageNet.OP_CLOSE, GuildStorageNet.encode_npc(npc))
