package session

// nakedBlow is a test monster's flat 15 on a starting character with no armour
// (round 875): the naked defence is Str 20 x the six body slots' naked scales
// (3.2 + 2.7 + 4.2 + 3.4 + 2.5 + 3.0 = 19.0 %) = 3.8, truncated to 3 -- READ
// (GObjPC_InitStats' table at s:0xc640d0), MEASURED (Str 491 reads 93).
const nakedBlow = 15 - 3
