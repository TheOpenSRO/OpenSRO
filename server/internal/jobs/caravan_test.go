package jobs

import "testing"

// script returns a dice that throws the values in order.
func script(t *testing.T, vals ...int) func() int {
	t.Helper()
	i := 0
	return func() int {
		if i >= len(vals) {
			t.Fatalf("dice thrown %d times, scripted %d", i+1, len(vals))
		}
		v := vals[i]
		i++
		return v
	}
}

func TestWaveDelay(t *testing.T) {
	if got := WaveDelayMs(script(t, 0)); got != 60000 {
		t.Fatalf("rand 0: %d", got)
	}
	if got := WaveDelayMs(script(t, RandMax)); got != 120000 {
		t.Fatalf("rand max: %d", got)
	}
	if got := WaveDelayMs(script(t, 16384)); got < 90000 || got > 90002 {
		t.Fatalf("rand half: %d", got)
	}
}

func TestWaveCount(t *testing.T) {
	// The shard's thresholds (t1 510) and factor 2300.
	if WaveCountBase(0, 510, 2300, false) != 0 || WaveCountBase(510, 510, 2300, false) != 1 ||
		WaveCountBase(511, 510, 2300, false) != 1 || WaveCountBase(2301, 510, 2300, false) != 2 ||
		WaveCountBase(4601, 510, 2300, false) != 3 {
		t.Fatal("the base count")
	}
	// A bargain good: ftol((v x 1.55 - 1) / factor + 1): 2300 -> 2.
	if got := WaveCountBase(2300, 510, 2300, true); got != 2 {
		t.Fatalf("bargain 2300: %d", got)
	}
	if got := WaveCountBase(10, 510, 2300, true); got != 1 {
		t.Fatalf("bargain 10: %d", got)
	}
	// 0 counts 1; a roll of half or more adds one; rand % 100 < 2 doubles.
	if WaveCount(0, script(t, 0, 50)) != 1 || WaveCount(1, script(t, 16384, 50)) != 2 ||
		WaveCount(2, script(t, 0, 1)) != 4 || WaveCount(2, script(t, RandMax, 101)) != 6 {
		t.Fatal("the rolls")
	}
}

func TestWaveTacticsAndKind(t *testing.T) {
	if WaveTacticsID(StateTrader, script(t, 2)) != 2004 || WaveTacticsID(StateTrader, script(t, 1, 6)) != 2003 ||
		WaveTacticsID(StateThief, script(t, 0)) != 2014 || WaveTacticsID(StateHunter, script(t, 3, 0)) != 2011 {
		t.Fatal("tactics ids")
	}
	if WaveMobKind(StateTrader) != MobNPCThief || WaveMobKind(StateThief) != MobNPCHunter {
		t.Fatal("kinds")
	}
}

func TestWaveLevel(t *testing.T) {
	// Level 50, scale 1: max(46, 16) - 1 + 1 + k.
	if got := WaveLevel(1, 50, script(t, 50, 0)); got != 46 {
		t.Fatalf("k 0: %d", got)
	}
	if got := WaveLevel(1, 50, script(t, 50, RandMax-1)); got != 49 {
		t.Fatalf("k 3: %d", got)
	}
	if got := WaveLevel(1, 50, script(t, 50, RandMax)); got != 50 {
		t.Fatalf("k 4 at rand max: %d", got)
	}
	// Scale 0 counts 1; the 2 % doubles p; a low level floors at 16.
	if got := WaveLevel(0, 10, script(t, 1, 0)); got != 16-1+2 {
		t.Fatalf("floor and double: %d", got)
	}
	if got := WaveLevel(3, 100, script(t, 99, 0)); got != 96-1+3 {
		t.Fatalf("scale 3: %d", got)
	}
}

func TestWaveGroupsAndPick(t *testing.T) {
	if WaveGroup("CHINA") != 0 || WaveGroup("west_china") != 0 || WaveGroup("Eu") != 1 || WaveGroup("KingsValley") != 1 ||
		WaveGroup("Thief Village") != 2 {
		t.Fatal("groups")
	}
	if MobGroup("MOB_THIEF_NPC_0001", MobNPCThief) != 0 || MobGroup("MOB_EU_THIEF_NPC_0001", MobNPCThief) != 1 ||
		MobGroup("MOB_HUNTER_NPC_0001", MobNPCHunter) != 0 || MobGroup("MOB_EU_HUNTER_NPC", MobNPCHunter) != 1 ||
		MobGroup("MOB_X", MobNPCThief) != 2 {
		t.Fatal("mob groups")
	}
	var tab MobLevels
	tab.Add(0, 1, 100)
	tab.Add(0, 5, 501)
	tab.Add(0, 5, 502)
	tab.Add(0, 140, 1400)
	if tab.Pick(0, 1, script(t)) != 0 {
		t.Fatal("level 1 picks nothing")
	}
	if tab.Pick(0, 3, script(t)) != 0 {
		t.Fatal("level 3 walks down to 2 and stops: level 1's rows are never looked at")
	}
	if tab.Pick(0, 7, script(t, 1)) != 502 {
		t.Fatal("level 7 walks down to 5")
	}
	if tab.Pick(0, 200, script(t, 0)) != 1400 {
		t.Fatal("past 140 is 140")
	}
	if tab.Pick(1, 50, script(t)) != 0 {
		t.Fatal("an empty group")
	}
}
