# How SR_GameServer routes a client message

Recovered 2026-09-17. The table this page describes is
`docs/protocol/server_handlers.tsv`: **162 message handlers**, the server-side
counterpart to `message_handlers.tsv`.

## One array, indexed by eleven bits

`CGObjPC::vslot_376` (`0x0050eee0`) is the entry point. Read in assembly:

	50ef08  mov   eax,[esi+0x1050]        ; the received message
	50ef0e  movzx ecx,WORD PTR [eax]      ; its opcode, 16 bits
	50ef11  mov   eax,ecx
	50ef13  and   eax,0x7ff               ; the index: the LOW ELEVEN BITS
	50ef18  and   ecx,0xfff
	50ef1e  cmp   cx,ax                   ; do they differ? then bit 0x800 is set
	50ef21  mov   ds:0xd6de18,ax          ; the current opcode, kept for later
	50ef28  je    0x50ef36                ; bit clear -> dispatch
	50ef2c  call  0x50ef60                ; bit set  -> the fallback
	50ef36  movzx eax,ax
	50ef39  add   eax,eax
	50ef3b  add   eax,eax                 ; index * 4
	50ef3d  mov   ecx,[eax+eax*1+0xcd3d0c]  ; index*8 + base+4: the `this` adjustor
	50ef44  mov   edx,[eax+eax*1+0xcd3d08]  ; index*8 + base:   the function
	50ef4d  add   ecx,edi                 ; this += adjustor
	50ef4f  call  edx

So the handler for a message is

	*(0x00cd3d08 + 8 * (opcode & 0x7ff))

an array of **pointers to member functions** (function plus `this` adjustor, 8
bytes each), 2,048 entries wide. **The server ignores the top five bits of the
opcode**, which is why a request and its reply can share an index.

## The table's contents come from code, not from the file

Nothing but the initialisers touches those addresses, and each entry is written by
a two-instruction pair:

	50d622  mov eax,0x518fd0              ; TrainingCamp_HandleOpen
	50d627  mov ds:0xcd6088,eax           ; 0xcd6088 = base + 8 * 0x470

`server_handlers.tsv` is every such assignment that lands inside the table: 224
assignments in the binary, **162 inside these bounds**, at indices `0x005`-`0x51c`.
Entries the initialisers never touch keep whatever default fills them, so this is
the set of handlers the server actually defines, not the whole 2,048.

## The index is the reply opcode's low eleven bits

Eleven handlers in the table were already named, from earlier work that never
touched this table, and **every one matches the client handler registered for the
reply opcode with the same eleven bits**:

	idx 062  CParty::CheckCanJoin                       <-> 0xb062
	idx 0e1  CInstanceCharTrijob::HandleJoinJobGuild    <-> 0xb0e1  (JobGuild_OnJoinResult)
	idx 0f0  CGuildManager::HandleCreateGuild           <-> 0xb0f0  (UI_GUILD)
	idx 117  GObjPC::HandleNameCOS                      <-> 0xb117
	idx 470  TrainingCamp_HandleOpen                    <-> 0xb470  (TrainingCamp_OnOpenResult)
	idx 471  TrainingCamp_HandleDisband                 <-> 0xb471  (TrainingCamp_OnDisbandResult)
	idx 472  TrainingCamp_HandleInvite                  <-> 0xb472
	idx 473  TrainingCamp_HandleBan                     <-> 0xb473
	idx 474  TrainingCamp_HandleLeave                   <-> 0xb474
	idx 475  TrainingCamp_HandleGraduation              <-> 0xb475
	idx 476  CInstanceTrainingCamp::CheckMembershipLevel <-> 0xb476

Eleven agreements, no disagreement. Two of those names were recovered this session
from opposite sides of the wire and had never been compared.

## The request opcodes, read from the client's send sites

The dispatcher's mask means the index alone does not give the opcode a client puts
on the wire. The client's own senders do:

	00821e40  FUN_00841780(0x7470, ...)    academy open
	008220e0  FUN_00841780(0x7471, ...)    academy disband
	00821f00  FUN_00841780(0x7472, ...)    academy invite (it shows UIIT_STT_TC_PROPOSAL_PENDING)
	00822180  FUN_00841780(0x7475, ...)    academy graduation

So the academy is `0x747x` out, `0xb47x` back, with the low eleven bits shared —
and both halves are read, not inferred from the pattern.

## What this opens

**47 of the 162 handlers are not functions in Ghidra at all**, the same gap the
client's registration table had before `CreateMissingFunctions.java` created 102
handlers there. Another **103 are still `FUN_`-style**. Creating and naming them is
the largest single naming lever left in the server, and every one of them has an
index, so each can be tied to the client's side of the same conversation.
