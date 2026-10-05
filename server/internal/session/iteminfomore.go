package session

import "errors"

// OpItemInfoMore carries the item-instance entries a list could not fit in
// its own frame (OURS, round 732 review F8): u8 container (ItemInfoBag,
// ItemInfoWorn, ItemInfoWarehouse), then the same block -- u16 count and
// the entries. Only a full warehouse needs it today: 210 slots of
// equipment with 12 options and an advanced elixir each overflow one frame
// (TestWorstCaseStorageListSplits); the bag (at most 100 slots) and the
// worn slots always fit. 0x00FB was free on both sides.
const OpItemInfoMore uint16 = 0x00FB

// The containers OpItemInfoMore names.
const (
	ItemInfoBag       = 0
	ItemInfoWorn      = 1
	ItemInfoWarehouse = 2
)

// splitInfos trims r.Infos to what fits the list's own frame and returns
// the rest, for OpItemInfoMore.
func (r *StorageListResult) splitInfos() []ItemInfo {
	infos := r.Infos
	r.Infos = nil
	r.Infos = fitItemInfos(len(r.Encode())-2, infos)
	return infos[len(r.Infos):]
}

// EncodeItemInfoMore packs entries into as many OpItemInfoMore payloads as
// they need, each within one frame.
func EncodeItemInfoMore(container byte, infos []ItemInfo) [][]byte {
	var out [][]byte
	for len(infos) > 0 {
		chunk := fitItemInfos(1, infos)
		if len(chunk) == 0 {
			break
		}
		out = append(out, encodeItemInfoBlock([]byte{container}, chunk))
		infos = infos[len(chunk):]
	}
	return out
}

// DecodeItemInfoMore reads one OpItemInfoMore payload.
func DecodeItemInfoMore(data []byte) (container byte, infos []ItemInfo, err error) {
	if len(data) < 1 {
		return 0, nil, errors.New("item info more: empty")
	}
	infos, err = decodeItemInfoBlock(data[1:])
	return data[0], infos, err
}
