package session

import (
	"os"
	"strings"
	"testing"
)

// Round 865 stage 3: the honor store's refusal travels as words on
// OpShopBuyResult (OURS, as the guild goods' do); the client maps them back
// to UIIT_MSG_TC_LACK_HONOR_POINT, the text the original prints for 0x18d4
// (READ c:0x7b9506 in its 0xB034 switch). The two must stay word for word.
func TestHonorLackReasonMappedByClient(t *testing.T) {
	src, err := os.ReadFile("../../../client/scripts/World3D.gd")
	if err != nil {
		t.Skip("no client tree beside the server:", err)
	}
	want := `"` + HonorLackReason + `": "UIIT_MSG_TC_LACK_HONOR_POINT"`
	if !strings.Contains(string(src), want) {
		t.Errorf("World3D.gd's GUILD_GOODS_REASONS does not map %q to UIIT_MSG_TC_LACK_HONOR_POINT", HonorLackReason)
	}
}
