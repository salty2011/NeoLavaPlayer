shader_type spatial;
render_mode unshaded, cull_back;
// LAVARndr fixed-function path: normalized vertex normals, point light0,
// infinite viewer, single-color specular, then GL_MODULATE texture.
uniform vec4 material_diffuse = vec4(1.0);
uniform vec3 material_ambient = vec3(1.0);
uniform vec3 material_specular = vec3(1.0);
uniform float shininess = 38.0;
uniform vec4 light_position = vec4(0.0, 2.0, 0.0, 1.0);
uniform vec3 light_diffuse = vec3(1.0);
uniform vec3 light_ambient = vec3(0.75);
// Lava3 draw 0x10019600 submits the light colour as both diffuse and specular.
uniform vec3 light_specular = vec3(1.0);
uniform bool vertex_ambient = true;
uniform bool lighting_enabled = true;
uniform bool has_texture = false;
// Style 0x80: scene 0x10025bda passes !flat to renderer +0xec (shade model).
// GL_FLAT keeps one lit colour per triangle (provoking vertex).
uniform bool flat_shading = false;
// Deliberately no source_color: original GL works on stored RGB values.
uniform sampler2D scene_texture : filter_linear_mipmap, repeat_enable;
varying vec4 primary_color;
// Classic colour fidelity across renderers: the original wrote raw GL RGB to
// an 8-bit sRGB-agnostic framebuffer. Compatibility stores the value as is;
// Forward+ renders linear HDR and encodes sRGB on output (with the Classic
// environment: linear tonemap, exposure 1, no glow/adjustments), so the raw
// value is pre-decoded here and the displayed bytes equal the original.
vec3 classic_output(vec3 raw) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
 return raw;
#else
 vec3 c = clamp(raw, vec3(0.0), vec3(1.0));
 return mix(pow((c + vec3(0.055)) / vec3(1.055), vec3(2.4)), c / vec3(12.92), lessThan(c, vec3(0.04045)));
#endif
}
varying flat vec4 primary_flat;
void vertex() {
 vec4 diffuse = material_diffuse * COLOR;
 if (lighting_enabled) {
  vec3 eye_position = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
  vec3 n = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
  vec4 eye_light = VIEW_MATRIX * light_position;
  vec3 l = normalize(eye_light.xyz - eye_position * eye_light.w);
  float facing = max(dot(n, l), 0.0);
  vec3 half_vector = normalize(l + vec3(0.0, 0.0, 1.0));
  float highlight = facing > 0.0 ? pow(max(dot(n, half_vector), 0.0), shininess) : 0.0;
  vec3 ambient = vertex_ambient ? diffuse.rgb : material_ambient;
  primary_color = vec4(clamp(ambient * light_ambient + diffuse.rgb * light_diffuse * facing + material_specular * light_specular * highlight, vec3(0.0), vec3(1.0)), diffuse.a);
 } else {
  primary_color = clamp(diffuse, vec4(0.0), vec4(1.0));
 }
 primary_flat = primary_color;
}
void fragment() {
 vec4 texel = has_texture ? texture(scene_texture, UV) : vec4(1.0);
 vec4 lit = flat_shading ? primary_flat : primary_color;
 ALBEDO = lit.rgb * texel.rgb;
 ALBEDO = classic_output(ALBEDO);
}
