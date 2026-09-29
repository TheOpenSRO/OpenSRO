extends RefCounted

## The colour the client draws a gold amount in: the more gold, the further
## along a white, yellow, orange, pink, violet, blue, cyan, green scale.
##
## READ (round 633): sro_client.exe 0x5d3df0(lo, hi) takes the 64-bit amount
## and divides it by 10^4, 10^5, ... 10^11 (`__alldiv`, 0x5d3e03..0x5d3eb7),
## returning the D3DCOLOR of the first power the amount is below:
##
##   amount <          10,000   0xFFFFFFFF   (255,255,255)
##   amount <         100,000   0xFFFFFA85   (255,250,133)
##   amount <       1,000,000   0xFFFFD348   (255,211, 72)
##   amount <      10,000,000   0xFFFFAD5C   (255,173, 92)
##   amount <     100,000,000   0xFFFF9AA1   (255,154,161)
##   amount <   1,000,000,000   0xFFEBA1FF   (235,161,255)
##   amount <  10,000,000,000   0xFFB8BBFF   (184,187,255)
##   amount < 100,000,000,000   0xFF95DEFF   (149,222,255)
##   otherwise                  0xFF8BFFE5   (139,255,229)
##
## (The division is signed and truncating, so "below" is |amount| < 10^n; a
## purse is never negative.) Its callers set the result as the number's font
## colour with 0x8b2b70, on the number's own static only -- the "Gold" caption
## beside it is a separate static that keeps its layout colour:
##
##   - the bag's purse, GDR_INVENTORY_STA_MONEY (ID 10): IFInventory 0x6b03a0,
##     the call at 0x6b045b;
##   - the warehouse's, GDR_STORAGE_STA_MONEY (ID 10): 0x6cc470, 0x6cc535
##     (CIFStorageRoom, so the guild storage too);
##   - the exchange's two offers, GDR_EXCHANGE_STATIC_MYMONEY (ID 19) and
##     _OTHERMONEY (ID 18): 0x7b23a0 / 0x7b2350, calls 0x7b23be / 0x7b236e.
##
## And not (read by the same census of the 20 call sites and the formatters'
## colour out-pointer): the store's prices and totals, the gold input box
## (its CIFEdit flags lack 0x400, the only path that colours an edit), and the
## item tooltips' price lines (they pass no colour pointer). The client also
## colours stall prices, the guild-war wager and the Open Market's prices,
## windows this client does not build.

## The amount thresholds, each paired with the colour of the amounts below it.
const STEPS := [
	[10000, 0xFFFFFFFF],
	[100000, 0xFFFFFA85],
	[1000000, 0xFFFFD348],
	[10000000, 0xFFFFAD5C],
	[100000000, 0xFFFF9AA1],
	[1000000000, 0xFFEBA1FF],
	[10000000000, 0xFFB8BBFF],
	[100000000000, 0xFF95DEFF],
]
## The colour of an amount of 10^11 or more.
const TOP := 0xFF8BFFE5

## The D3DCOLOR (0xAARRGGBB) 0x5d3df0 returns for `amount`.
static func argb(amount: int) -> int:
	var magnitude := absi(amount)
	for step in STEPS:
		if magnitude < int(step[0]):
			return int(step[1])
	return TOP

## The same colour as a Godot Color.
static func of(amount: int) -> Color:
	var c := argb(amount)
	return Color8((c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff, (c >> 24) & 0xff)
