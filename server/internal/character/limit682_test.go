package character

import "testing"

// TestRetailLimitIsFour: 4 characters an account, READ (the client refuses
// Create at four, 0x85de50; ShardManager refuses a fifth with 0x405) and the
// user's decision 2 (2026-10-02). NEGATIVE: before round 682 the limit was 3
// and this fails.
func TestRetailLimitIsFour(t *testing.T) {
	if MaxPerAccount != 4 {
		t.Errorf("MaxPerAccount = %d, want retail's 4", MaxPerAccount)
	}
}
