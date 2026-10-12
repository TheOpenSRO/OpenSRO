package quest

import (
	"reflect"
	"strings"
	"testing"
)

// A made-up DeclareQuestContent in the decompilation's shape (no retail
// decompilation is a fixture): a two-NPC gather quest with a prerequisite.
const fakeDecomp = `===FUNC=== 00900000 CQNO_T_GATHER::DeclareQuestContent size=600

bool __fastcall CQNO_T_GATHER::DeclareQuestContent(int *param_1)
{
  *(uint *)param_1[0xc2] = *(uint *)param_1[0xc2] | 2;
  *(undefined1 *)((int)param_1 + 0x2d) = 1;
  FUN_00401fc0("QNO_T_FIRST",0xb);
  FUN_00476cd0(local_50);
  *(uint *)param_1[0xc2] = *(uint *)param_1[0xc2] | 1;
  *(undefined4 *)(param_1[0xc2] + 0x23) = 0xb;
  *(undefined4 *)(param_1[0xc2] + 4) = 1;
  *(uint *)param_1[0xc4] = *(uint *)param_1[0xc4] | 1;
  *(undefined4 *)(param_1[0xc4] + 4) = 2;
  *(char **)(param_1[0xc4] + 8) = "NPC_T_START";
  *(char **)(param_1[0xc4] + 0xc) = "NPC_T_END";
  FUN_00401fc0("NPC_T_END",0x9);
  FUN_00476cd0(local_50);
  FUN_00401fc0("NPC_T_START",0xb);
  FUN_00476cd0(local_34);
  param_1[0x121] = 2;
  puVar3 = (undefined4 *)FUN_009dd2bc(0x25a);
  if (puVar3 == (undefined4 *)0x0) {
    puVar3 = (undefined4 *)0x0;
  }
  else {
    *(undefined4 *)((int)puVar3 + 0x19) = 0;
  }
  uVar2 = _DAT_00b00010;
  *(undefined4 *)((int)puVar3 + 0x14d) = uVar2;
  *(undefined4 *)((int)puVar3 + 9) = 1;
  *(undefined4 *)((int)puVar3 + 0x19) = 1;
  *(undefined1 *)(puVar3 + 2) = 0;
  *(char **)((int)puVar3 + 0x15) = "NPC_T_END";
  *(char **)((int)puVar3 + 0xd) = "SN_CON_QNO_T_GATHER";
  *(char **)((int)puVar3 + 0x1d) = "MOB_T_WOLF";
  *(undefined4 *)((int)puVar3 + 0x23d) = 0x14;
  *(char **)((int)puVar3 + 0x241) = "ITEM_QNO_T_PELT";
  FUN_009173b0();
  iVar2 = FUN_009dd2bc(0xa7);
  *(undefined4 *)((int)puVar3 + 9) = 6;
  *(undefined1 *)(puVar3 + 2) = 1;
  *(char **)((int)puVar3 + 0x15) = "NPC_T_END";
  *(char **)((int)puVar3 + 0x1e) = "SN_TALK_QNO_T_GATHER_05";
  FUN_009173b0();
  param_1[0x126] = (int)"SN_NPC_T_START_QS";
  param_1[0x127] = (int)"SN_NPC_T_END_QS";
  param_1[0x130] = (int)"SN_TALK_QNO_T_GATHER_01";
  param_1[0x13d] = (int)"SN_TALK_QNO_T_GATHER_06";
  return iVar2 != 0;
}


===FUNC=== 00900400 CQNO_T_GATHER::FUN_00900400 size=10
`

func TestParseCompiledSetup(t *testing.T) {
	floats := func(va uint32) (float64, bool) { return 33, va == 0xb00010 }
	setups := ParseDecomp(strings.NewReader(fakeDecomp), floats)
	cs := setups["QNO_T_GATHER"]
	if cs == nil {
		t.Fatalf("setups %v", setups)
	}
	q := &Quest{ID: 1, Code: "QNO_T_GATHER", Source: SourceCompiled}
	ApplyCompiled(q, cs)
	if q.Level != 11 || q.ConditionMask != 3 || q.AchievementLimit != 1 || !reflect.DeepEqual(q.Requires, []string{"QNO_T_FIRST"}) {
		t.Fatalf("conditions %+v", q)
	}
	if !reflect.DeepEqual(q.StartNPCs, []string{"NPC_T_START"}) || !reflect.DeepEqual(q.CompleteNPCs, []string{"NPC_T_END"}) {
		t.Fatalf("npcs start %v complete %v", q.StartNPCs, q.CompleteNPCs)
	}
	if len(q.Missions) != 2 {
		t.Fatalf("missions %+v", q.Missions)
	}
	g := q.Missions[0]
	if g.Type != MissionGatherFromMonster || g.Count != 20 || g.Item != "ITEM_QNO_T_PELT" || !reflect.DeepEqual(g.Targets, []string{"MOB_T_WOLF"}) ||
		!reflect.DeepEqual(g.Rates, []float64{33}) || g.NPC != "NPC_T_END" {
		t.Fatalf("gather %+v", g)
	}
	d := q.Missions[1]
	if d.Type != MissionDialog || d.Index != 1 || !reflect.DeepEqual(d.Talk, []string{"SN_TALK_QNO_T_GATHER_05"}) {
		t.Fatalf("dialog %+v", d)
	}
	if q.MenuText("NPC_T_START", "BASIC_MENUSTRING_REQUEST_ACCEPT_QUEST") != "SN_TALK_QNO_T_GATHER_01" ||
		q.MenuText("NPC_T_START", "BASIC_MENUSTRING_MIDDLE_ACHIEVED") != "SN_TALK_QNO_T_GATHER_06" ||
		q.MenuText("NPC_T_END", "BASIC_MENUSTRING_GREETING") != "SN_NPC_T_END_QS" ||
		q.MenuText("NPC_T_END", "BASIC_MENUSTRING_ACHIEVED") != "SN_TALK_QNO_T_GATHER_05" {
		t.Fatalf("menus %+v", q.Menus)
	}
	if !q.Playable() {
		t.Fatal("a compiled quest of modelled missions is playable")
	}
}
