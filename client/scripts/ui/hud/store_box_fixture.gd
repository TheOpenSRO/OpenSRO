extends RefCounted
class_name StoreBoxFixture

## Test support (round 726): a UiBuilder whose layout cache holds synthetic
## copies of the four layouts StoreMessageBox builds from -- the controls'
## real names, types, IDs, rects and text keys (MEASURED from Media.pk2's
## ifmessagebox.txt, ifitemmallconfirmbuy.txt and ifitemmallconfirmslot.txt,
## RENEWAL branch), no art. The OK/Cancel buttons the files author at size
## 0,0 (drawn at com_button.ddj's own 76x24) carry that size here, since
## there is no art to take it from. Nothing from the archive is committed: these are
## rects and keys, as the protocol docs quote them.

const CREATE := """
Section = Create,"0,0,0,0","0"
{
	GDR_MSGBOX_BG:CIFNormalTile
	{
		ID=INTEGER,"0"
		Rect=RECT,"16,40,284,122"
	}
}
"""

const STORE_CONFIRM := """
Section = MsgBoxStoreConfirm,"0,0,0,0","0"
{
	GDR_MBS_CONFIRM_EDIT_PRICE:CIFEdit
	{
		HAlign=INTEGER,"2"
		ID=INTEGER,"85"
		Rect=RECT,"112,102,104,17"
	}
	GDR_MBS_CONFIRM_STA_GOLD:CIFStatic
	{
		ID=INTEGER,"87"
		Rect=RECT,"222,100,15,16"
		Text=STRING,"UIIT_STT_GOLD"
	}
	GDR_MBS_CONFIRM_STA_PRICE:CIFStatic
	{
		HAlign=INTEGER,"2"
		ID=INTEGER,"86"
		Rect=RECT,"50,100,53,16"
		Text=STRING,"UIIT_CTL_WARENETWORK_RESULT_PRICE"
	}
	GDR_MBS_CONFIRM_BTN_CANCEL:CIFButton
	{
		ID=INTEGER,"84"
		Rect=RECT,"170,135,76,24"
		Text=STRING,"UIIS_CTL_CANCEL"
	}
	GDR_MBS_CONFIRM_BTN_SELL:CIFButton
	{
		ID=INTEGER,"83"
		Rect=RECT,"82,135,76,24"
		Text=STRING,"UIIT_STT_SELL"
	}
	GDR_MBS_CONFIRM_SPINBTN_DOWN:CIFButton
	{
		ID=INTEGER,"82"
		Rect=RECT,"278,85,22,12"
	}
	GDR_MBS_CONFIRM_SPINBTN_UP:CIFButton
	{
		ID=INTEGER,"81"
		Rect=RECT,"278,74,22,12"
	}
	GDR_MBS_CONFIRM_EDIT_COUNT:CIFEdit
	{
		HAlign=INTEGER,"2"
		ID=INTEGER,"80"
		Rect=RECT,"237,80,36,12"
	}
	GDR_MBS_CONFIRM_EDIT_ITEM_NAME:CIFEdit
	{
		HAlign=INTEGER,"1"
		ID=INTEGER,"79"
		Rect=RECT,"86,53,209,14"
	}
	GDR_MBS_CONFIRM_STA_COUNT:CIFStatic
	{
		ID=INTEGER,"78"
		Rect=RECT,"198,80,33,14"
		Text=STRING,"UIIT_STT_AMOUNT"
	}
	GDR_MBS_CONFIRM_BUY_ITEM_ICON:CIFStatic
	{
		ID=INTEGER,"73"
		Rect=RECT,"28,55,32,32"
	}
	GDR_MBS_CONFIRM_BUY_BG:CIFNormalTile
	{
		ID=INTEGER,"70"
		Rect=RECT,"16,40,295,106"
	}
}
"""

const STORE_MONEY := """
Section = MsgBoxStoreMoney,"0,0,0,0","0"
{
	GDR_MBS_EDIT_PRICE:CIFEdit
	{
		ID=INTEGER,"11"
		Rect=RECT,"127,68,121,18"
		Style=INTEGER,"64"
	}
	GDR_MBS_BTN_CANCEL:CIFButton
	{
		ID=INTEGER,"216"
		Rect=RECT,"203,101,76,24"
	}
	GDR_MBS_BTN_OK:CIFButton
	{
		ID=INTEGER,"215"
		Rect=RECT,"123,101,76,24"
	}
	GDR_MBS_STATIC_AMOUNT:CIFStatic
	{
		ID=INTEGER,"4"
		Rect=RECT,"64,108,12,12"
		Text=STRING,"UIIT_STT_UNIT"
	}
	GDR_MBS_EDIT_AMOUNT:CIFEdit
	{
		ClientRect=RECT,"7,5,7,5"
		HAlign=INTEGER,"2"
		ID=INTEGER,"3"
		Rect=RECT,"20,102,42,20"
	}
	GDR_MBS_STATIC_PRICET1:CIFStatic
	{
		ID=INTEGER,"8"
		Rect=RECT,"77,71,43,12"
		Text=STRING,"UIIT_STT_PRICE"
	}
	GDR_MBS_STATIC_PRICET2:CIFStatic
	{
		ID=INTEGER,"7"
		Rect=RECT,"255,72,23,12"
		Text=STRING,"UIIT_STT_GOLD"
	}
	GDR_MBS_STATIC_PRICE:CIFStatic
	{
		ID=INTEGER,"2"
		Rect=RECT,"127,71,121,12"
	}
	GDR_MBS_STATIC_NAME2:CIFStatic
	{
		ID=INTEGER,"9"
		Rect=RECT,"73,53,212,28"
	}
	GDR_MBS_STATIC_NAME1:CIFStatic
	{
		ID=INTEGER,"1"
		Rect=RECT,"73,44,212,48"
	}
	GDR_MBS_STATIC_ICON:CIFStatic
	{
		ID=INTEGER,"12"
		Rect=RECT,"25,51,32,32"
	}
}
"""

## Round 728: MsgBoxDivideCount, as STORE_CONFIRM (MEASURED, rects and keys).
const DIVIDE_COUNT := """
Section = MsgBoxDivideCount,"0,0,0,0","0"
{
	GDR_MBDC_BTN_CANCEL:CIFButton
	{
		ID=INTEGER,"221"
		Rect=RECT,"151,143,76,24"
		Text=STRING,"UIIT_CTL_CANCEL"
	}
	GDR_MBDC_BTN_OK:CIFButton
	{
		ID=INTEGER,"220"
		Rect=RECT,"71,143,76,24"
		Text=STRING,"UIIT_CTL_CONFIRM"
	}
	GDR_MBDC_STATIC_DIVIDE_AMOUNT_EDIT:CIFEdit
	{
		ClientRect=RECT,"7,5,7,5"
		HAlign=INTEGER,"1"
		ID=INTEGER,"17"
		Rect=RECT,"223,102,42,24"
	}
	GDR_MBDC_STATIC_DIVIDE:CIFStatic
	{
		ID=INTEGER,"16"
		Rect=RECT,"153,106,64,19"
		Text=STRING,"UIIT_MSG_MSGBOX_DIVIDE_COUNT"
	}
	GDR_MBDC_STATIC_CURRENT_AMOUNT:CIFStatic
	{
		ID=INTEGER,"15"
		Rect=RECT,"105,106,41,19"
	}
	GDR_MBDC_STATIC_CURRENT:CIFStatic
	{
		ID=INTEGER,"14"
		Rect=RECT,"34,106,64,19"
		Text=STRING,"UIIT_MSG_MSGBOX_CURRENT_COUNT"
	}
	GDR_MBDC_STATIC_BOXDESC:CIFStatic
	{
		ID=INTEGER,"13"
		Rect=RECT,"77,68,202,19"
		Text=STRING,"UIIT_MSG_MSGBOX_DIVIDE_CURRENT_ITEM"
	}
	GDR_MBDC_STATIC_NAMEBOARD:CIFStatic
	{
		ClientRect=RECT,"4,3,6,26"
		ID=INTEGER,"12"
		Rect=RECT,"73,44,212,48"
	}
	GDR_MBDC_STATIC_ICON:CIFStatic
	{
		ID=INTEGER,"11"
		Rect=RECT,"25,51,32,32"
	}
	GDR_MBDC_STATIC_ICONWND:CIFStatic
	{
		ID=INTEGER,"10"
		Rect=RECT,"18,44,48,48"
	}
}
"""

const CONFIRM_BUY := """
Section = Create,"0,0,0,0","0"
{
	GDR_ITEMMALL_CONFIRM_BTN_CANCEL:CIFButton
	{
		ID=INTEGER,"62"
		Rect=RECT,"0,0,76,24"
		Text=STRING,"UIIS_CTL_CANCEL"
	}
	GDR_ITEMMALL_CONFIRM_BTN_BUY:CIFButton
	{
		ID=INTEGER,"61"
		Rect=RECT,"0,0,76,24"
		Text=STRING,"UIIT_STT_BUY"
	}
	GDR_ITEMMALL_CONFIRM_SPINBTN_DOWN:CIFButton
	{
		ID=INTEGER,"51"
		Rect=RECT,"278,85,22,12"
	}
	GDR_ITEMMALL_CONFIRM_SPINBTN_UP:CIFButton
	{
		ID=INTEGER,"50"
		Rect=RECT,"278,74,22,12"
	}
	GDR_ITEMMALL_CONFIRM_EDIT_COUNT:CIFEdit
	{
		HAlign=INTEGER,"2"
		ID=INTEGER,"42"
		Rect=RECT,"237,80,36,12"
	}
	GDR_ITEMMALL_CONFIRM_EDIT_ITEM_NAME:CIFEdit
	{
		HAlign=INTEGER,"1"
		ID=INTEGER,"40"
		Rect=RECT,"86,53,209,14"
	}
	GDR_ITEMMALL_CONFIRM_STA_COUNT:CIFStatic
	{
		ID=INTEGER,"21"
		Rect=RECT,"198,80,33,14"
		Text=STRING,"UIIT_STT_AMOUNT"
	}
	GDR_ITEMMALL_CONFIRM_BUY_ITEM_ICON:CIFStatic
	{
		ID=INTEGER,"11"
		Rect=RECT,"28,55,32,32"
	}
	GDR_ITEMMALL_CONFIRM_BUY_TITLE:CIFStatic
	{
		HAlign=INTEGER,"1"
		ID=INTEGER,"5"
		Rect=RECT,"84,12,162,14"
		Text=STRING,"UIIT_STT_CONFIRM_BOX"
	}
	GDR_ITEMMALL_CONFIRM_BUY_BG:CIFNormalTile
	{
		ID=INTEGER,"4"
		Rect=RECT,"16,40,295,106"
	}
}
"""

const CONFIRM_SLOT := """
Section = Create,"0,0,0,0","0"
{
	GDR_ITEMMALL_CONFIRM_STA_2:CIFStatic
	{
		ID=INTEGER,"5"
		Rect=RECT,"222,2,15,16"
	}
	GDR_ITEMMALL_CONFIRM_STA_1:CIFStatic
	{
		HAlign=INTEGER,"2"
		ID=INTEGER,"4"
		Rect=RECT,"50,2,53,16"
	}
	GDR_ITEMMALL_CONFIRM_EDIT:CIFEdit
	{
		HAlign=INTEGER,"2"
		ID=INTEGER,"3"
		Rect=RECT,"112,2,102,16"
	}
}
"""

## A builder with the four layouts in its cache, under the keys
## StoreMessageBox's load_layout asks for.
static func builder() -> UiBuilder:
	var b := UiBuilder.new(null, null)
	var defines := PackedStringArray(StoreMessageBox.DEFINES)
	# UiBuilder.load_layout's own key: the path, \x01, the defines joined by \x02.
	var key := String.chr(1) + String.chr(2).join(defines)
	# Straight into the builder's own cache (Object.get hands back a copy).
	b._layout_cache[StoreMessageBox.MSGBOX_LAYOUT + key] = UiLayoutParser.parse(CREATE + STORE_CONFIRM + STORE_MONEY + DIVIDE_COUNT, true, defines)
	b._layout_cache[StoreMessageBox.CONFIRM_BUY_LAYOUT + key] = UiLayoutParser.parse(CONFIRM_BUY, true, defines)
	b._layout_cache[StoreMessageBox.CONFIRM_SLOT_LAYOUT + key] = UiLayoutParser.parse(CONFIRM_SLOT, true, defines)
	return b
