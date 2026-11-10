package session

// nakedBlow is a test monster's flat 15 on a starting character with no armour
// (round 875): the naked defence is Str 20 x the six body slots' naked scales
// (3.2 + 2.7 + 4.2 + 3.4 + 2.5 + 3.0 = 19.0 %) = 3.8 -- READ (GObjPC_InitStats'
// table at s:0xc640d0), MEASURED (Str 491 reads 93). The character window
// truncates it to 3; a blow takes the 3.8 off unrounded (round 880,
// defenderArmorExact) and is truncated itself: 15 - 3.8 = 11.2 -> 11.
const nakedBlow = 11
