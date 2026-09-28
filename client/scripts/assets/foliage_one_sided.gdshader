shader_type spatial;
// One-sided: an alpha-tested layer WITHOUT 0x1 in its flag word keeps the
// client's default cull (READ, round 625) -- pine and bamboo needle cards
// (0x340). The .bms winding is reversed on load (BmsReader.to_arrays), so
// Godot's back-face cull is the client's CCW cull.
render_mode cull_back;

#include "res://scripts/assets/foliage.gdshaderinc"
