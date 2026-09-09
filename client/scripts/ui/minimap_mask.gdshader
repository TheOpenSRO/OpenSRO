shader_type canvas_item;

// Clips the minimap's region art to the circular aperture in the minimap
// frame, using the client's own mask artwork.
//
// `interface\minimap\mm_alpha.ddj` is a 104x104 image whose RGB is black
// everywhere and whose alpha is 255 inside a circle and 0 outside -- a pure
// alpha mask. The authored layout places it at exactly the map rect
// (GDR_MINIMAP_ALPHA, 14,57,105,105 in resinfo\ifminimap.txt), which is how
// the real client rounds off the map. Drawn as ordinary artwork it is just
// a black disc that hides the map completely.
//
// The map quad is larger than the aperture and slides around inside it as
// the player moves, so the mask cannot be sampled at the quad's own UV. It
// is sampled in aperture space instead: `map_offset` and `map_size` give
// the quad's rect relative to the aperture's top-left, and `aperture_size`
// normalises that to the mask's 0..1 range.

uniform sampler2D mask_texture : filter_linear;
uniform vec2 map_offset = vec2(0.0);
uniform vec2 map_size = vec2(1.0);
uniform vec2 aperture_size = vec2(1.0);

void fragment() {
	vec2 aperture_uv = (map_offset + UV * map_size) / aperture_size;
	// Outside the aperture there is no mask to sample; clamping would smear
	// the mask's edge texels outward and paint map over the frame.
	if (aperture_uv.x < 0.0 || aperture_uv.x > 1.0 || aperture_uv.y < 0.0 || aperture_uv.y > 1.0) {
		discard;
	}
	COLOR.a *= texture(mask_texture, aperture_uv).a;
}
