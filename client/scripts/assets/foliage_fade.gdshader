shader_type spatial;
// foliage.gdshader while a character fades into existence (AppearFade, round
// 676): blended at the fade's alpha. depth_draw_always keeps the model's near
// faces in front of its far ones while it is translucent (OURS).
render_mode cull_disabled, blend_mix, depth_draw_always;

#define APPEAR_FADE
#include "res://scripts/assets/foliage.gdshaderinc"
