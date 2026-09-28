shader_type spatial;
// Two-sided: the layer's flag word has 0x1, D3DCULL_NONE (READ, round 625).
render_mode cull_disabled;

#include "res://scripts/assets/foliage.gdshaderinc"
