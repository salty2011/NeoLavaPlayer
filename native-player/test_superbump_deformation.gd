extends SceneTree
## Headless checks for superbump_deformation.gd (DefSuperBump, Lava3.dll ctor 0x10007360,
## update 0x100092c0). Run:
## Godot --headless --audio-driver Dummy --path native-player --script res://test_superbump_deformation.gd
const SuperBump = preload("res://superbump_deformation.gd")
const RAD := 0.01745329238474369
const PI32 := 3.1415927410125732
var failures: Array = []
var notes := {}
var fixed_value := 0.5

func _initialize() -> void:
	call_deferred("verify")

func check(name: String, ok: bool, detail: Variant = "") -> void:
	if not ok: failures.append("%s %s" % [name, str(detail)])

func near(x: float, y: float, eps := 1e-9) -> bool:
	return absf(x-y) <= eps

func fixed() -> float:
	return fixed_value

func load_preset(path: String, index: int) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	var presets: Array = []
	while not file.eof_reached():
		var parts := file.get_line().strip_edges().split("\t")
		if parts.size() < 2: continue
		if parts[0] == "Preset": presets.append({})
		elif not presets.is_empty(): presets[-1][parts[0]] = float(parts[1])
	return presets[index]

## Sphere grid; angular pair = Vector2(phi, theta) like bump_deformation.gd callers.
func sphere(nx: int, ny: int) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var v := PackedVector3Array(); var n := PackedVector3Array(); var uv := PackedVector2Array()
	var params := PackedVector2Array()
	for j in range(ny+1):
		var phi := PI32*float(j)/float(ny)
		for i in range(nx):
			var theta := 2.0*PI32*float(i)/float(nx)
			var p := Vector3(sin(phi)*cos(theta), cos(phi), sin(phi)*sin(theta))
			v.append(p); n.append(p); params.append(Vector2(phi, theta))
			uv.append(Vector2(theta*0.15915493667125702, (PI32-phi)*0.31830987334251404))
	arrays[Mesh.ARRAY_VERTEX] = v; arrays[Mesh.ARRAY_NORMAL] = n; arrays[Mesh.ARRAY_TEX_UV] = uv
	return [arrays, params]

func max_disp(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var m := 0.0
	for i in range(a.size()): m = maxf(m, (a[i]-b[i]).length())
	return m

func sum_disp(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var t := 0.0
	for i in range(a.size()): t += (a[i]-b[i]).length()
	return t

func verify() -> void:
	# 1. Random helpers 0x10010b70 / 0x10010b30 / 0x10010ba0 with a fixed U[0,1] draw.
	var sb = SuperBump.new()
	sb.random_source = Callable(self, "fixed")
	sb.reset({})
	fixed_value = 0.5
	check("rand_range", near(sb._uniform(60.0, 90.0), 75.0))
	check("rand_int", sb._integer(2.0, 8.0) == 5.0 and sb._integer(1.0, 1.0) == 1.0)
	fixed_value = 1.0
	check("rand_int_top", sb._integer(2.0, 8.0) == 8.0)
	fixed_value = 0.4999
	check("rand_sign_neg", sb._rsign() == -1.0)
	fixed_value = 0.5
	check("rand_sign_pos", sb._rsign() == 1.0)

	# 2. Ctor defaults (0x10007360) and setter aliases/ignored names (0x10007db0).
	sb.reset({"CentVelocityMin": 10.0, "DoTex": 0.0, "FlowNMa": 3.0, "Interruptlevel": 0.9, "DoWave": 1.7})
	var p: Dictionary = sb.parameters()
	check("defaults", p["DecayMin"] == 0.75 and p["BumpSigmaMax"] == 180.0 and p["TexRestDecay"] == 0.175 \
		and p["DoTextureRestore"] == 1 and p["CentBounceTheta"] == 1 and p["MapColorRatio"] == 1.0, p)
	check("aliases", p["CentVMin"] == 10.0 and p["DoTexture"] == 0 and p["FlowNMax"] == 8.0 \
		and p["InteruptLevel"] == 0.0 and p["DoWave"] == 1, p)

	# 3. Raised-cosine profile 0x1000abd1.
	check("profile", near(SuperBump.bump_profile(0.0, 1.0), 1.0) and near(SuperBump.bump_profile(0.5, 1.0), 0.5, 1e-7) \
		and SuperBump.bump_profile(1.01, 1.0) == 0.0)

	# 4. Spawn (0x10009966..) with constant draw 0.5 and default preset.
	sb.reset({"DoTextureRestore": 0, "DoTexture": 0})
	sb.advance(1.0, 0.0)
	var ev: Dictionary = sb._events[0]
	check("spawn_active", bool(ev["active"]) and ev["peak"] == 1.0 and ev["duration"] == 0.75)
	check("spawn_center", near(ev["theta"], 180.0*RAD) and near(ev["phi"], 180.0*RAD), [ev["theta"], ev["phi"]])
	check("spawn_velocity", near(ev["vtheta"], -270.0*RAD, 1e-7) and absf(ev["vphi"]) < 1e-6, [ev["vtheta"], ev["vphi"]])
	check("spawn_sigma", ev["sign"] == 1.0 and ev["sigma_dir"] == 1.0 and near(ev["sigma"], 75.0*RAD) and near(ev["vsigma"], 270.0*RAD))
	check("spawn_spin", near(ev["vi"], 75.0*RAD) and near(ev["vo"], 360.0*RAD) and ev["itheta"] == 0.0 and ev["otheta"] == 0.0, [ev["vi"], ev["vo"]])
	check("spawn_wave", ev["wave_m"] == 5.0 and ev["wave_n"] == 5.0 and near(ev["wave_w"], 540.0*RAD) \
		and near(ev["wave_depth"], 0.75) and near(ev["wave_amp"], 5.0*RAD))
	check("spawn_flow", ev["flow_m"] == 2.0 and ev["flow_n"] == 5.0 and near(ev["flow_depth"], 1.0))
	check("spawn_tex", near(ev["tex_sx"], 0.625) and ev["tex_ix"] == 1.0 and near(ev["map_sy"], 0.625))

	# 5. One state tick, A=0 (no trigger): envelope, centre motion env*S*dt, sigma growth.
	var theta0: float = ev["theta"]; var vth: float = ev["vtheta"]
	sb.advance(0.0, 0.1, Color.WHITE, 2.0)
	ev = sb._events[0]
	var env := (cos(0.1*PI32/0.75)+1.0)*0.5
	check("envelope", near(ev["envelope"], env), ev["envelope"])
	check("center_motion", near(ev["theta"], theta0+vth*env*2.0*0.1), [ev["theta"], theta0+vth*env*0.2])
	check("sigma_growth", near(ev["sigma"], 102.0*RAD), ev["sigma"]/RAD)
	check("inner_outer", near(ev["itheta"], 7.5*RAD) and near(ev["otheta"], 36.0*RAD))
	check("spacing", near(sb._spacing, 0.1))

	# 6. Weight, displacement and colour at centre and at r = sigma/2 (rot from inner/outer twist).
	var sigma: float = ev["sigma"]
	var c_phi: float = ev["phi"]; var c_theta: float = ev["theta"]
	var mesh := []
	mesh.resize(Mesh.ARRAY_MAX)
	mesh[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
	mesh[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	mesh[Mesh.ARRAY_COLOR] = PackedColorArray([Color(0, 0, 0, 0.5), Color(0, 0, 0, 0.5), Color(0, 0, 0, 0.5)])
	var params := PackedVector2Array([Vector2(c_phi*0.5, c_theta), Vector2(c_phi*0.5, c_theta+sigma*0.5), Vector2(c_phi*0.5, c_theta+sigma*1.5)])
	var out: Array = sb.deform(mesh, params, 0.0, 2.0, 0.0, 3.0)
	var k: float = 1.0*1.0*2.0*float(sb._events[0]["envelope"])
	var verts: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
	check("disp_center", near(verts[0].y, k*3.0, 1e-7), verts[0])
	check("disp_half_sigma", near(verts[1].y, 0.5*k*3.0, 1e-6), verts[1])
	check("disp_outside", verts[2] == Vector3.ZERO, verts[2])
	var cols: PackedColorArray = out[Mesh.ARRAY_COLOR]
	var cur: Color = sb._events[0]["current"]
	check("color_blend", near(cols[0].r, cur.r, 1e-6) and near(cols[1].g, cur.g*0.5, 1e-6) and cols[1].a == 0.5 and cols[2] == Color(0, 0, 0, 0.5), [cols, cur])

	# 7. Wave / flow modulation (0x1000ac0e, 0x1000ac7e) against hand formula.
	sb.configure({"DoWave": 1})
	ev = sb._events[0]
	var r := sigma*0.5
	var rot: float = ev["itheta"]+(ev["otheta"]-ev["itheta"])*(r/sigma*2.0)
	var ang := atan2(r*sin(rot), r*cos(rot))
	var wave: float = cos((cos(ang*ev["wave_n"])*ev["wave_amp"]+r)*ev["wave_m"]+ev["wave_t"]*ev["wave_w"])*ev["wave_depth"]+1.0-ev["wave_depth"]
	var got: Vector3 = sb.event_weight(ev, params[1])
	check("wave", near(got.x, 0.5*wave, 1e-6), [got.x, 0.5*wave])
	check("rotated_coords", near(got.y, r*cos(rot), 1e-6) and near(got.z, r*sin(rot), 1e-6), got)
	sb.configure({"DoWave": 0, "DoFlow": 1})
	var fd: float = r*ev["flow_depth"]*(2.0/sigma)
	var flow: float = cos((cos(ev["flow_t"]*ev["flow_w"]+r*ev["flow_n"])*ev["flow_amp"]+ang)*ev["flow_m"])*fd+1.0-fd
	got = sb.event_weight(ev, params[1])
	check("flow", near(got.x, 0.5*flow, 1e-6), [got.x, 0.5*flow])

	# 8. Texture restore half-life and mask/heightmap row convention (loader 0x10010e80).
	sb.reset({"DoTextureRestore": 1, "TexRestDecay": 0.25, "DoTexture": 0})
	sb.texture_mapping = {"repeat_u": 1.0, "repeat_v": 1.0, "offset_u": 0.0, "offset_v": 0.0, "bias_u": 0.0, "bias_v": 0.0}
	var one := []
	one.resize(Mesh.ARRAY_MAX)
	one[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO]); one[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP])
	one[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(1.0, 1.0)])
	var out_uv: PackedVector2Array = sb.deform(one, PackedVector2Array([Vector2(PI32*0.5, PI32)]), 0.0, 1.0, 0.25)[Mesh.ARRAY_TEX_UV]
	check("tex_restore", near(out_uv[0].x, 0.75, 1e-6) and near(out_uv[0].y, 0.75, 1e-6), out_uv)
	var img := Image.create(3, 3, false, Image.FORMAT_RGB8)
	img.fill(Color8(0, 0, 0))
	img.set_pixel(0, 0, Color8(255, 255, 255))
	img.set_pixel(2, 2, Color8(128, 0, 0))
	var m: Dictionary = SuperBump.build_map(img, 0.0)
	check("map_rows", near(m["height"][2*3+0], 1.0) and near(m["height"][0*3+2], 128.0/765.0, 1e-6) and near(m["rgb"][2*3+0].r, 255.0/256.0), m["height"])
	sb.set_mask_map(img)
	check("mask_sample", near(sb._mask_sample(Vector2(0.0, 0.0)), 1.0) and near(sb._mask_sample(Vector2(-0.1, 0.0)), 0.0) \
		and near(sb._mask_sample(Vector2(0.9, 0.9)), 128.0/765.0, 1e-6))

	# 9. deform path vs advance path: identical state and identical CRT draw count.
	var lvt7 := load_preset("res://scenes/lava25/LVT7/defSuperBump.lvd", 0)
	var hm := Image.load_from_file(ProjectSettings.globalize_path("res://scenes/lava25/LVT7/heightmap0.bmp"))
	var mk := Image.load_from_file(ProjectSettings.globalize_path("res://scenes/lava25/LVT7/maskmap0.bmp"))
	var grid := sphere(24, 12)
	var a = SuperBump.new(); var b = SuperBump.new()
	a.reset(lvt7, 3); b.reset(lvt7, 3)
	a.set_height_map(hm); a.set_mask_map(mk)
	var same := true
	var peak := 0.0
	var dt := 1.0/60.0
	for f in range(240):
		var amp := 0.5+0.5*sin(float(f)*0.37)
		var res: Array = a.deform(grid[0], grid[1], amp, 1.0, dt, 1.0, Color(0.8, 0.3, 0.2))
		b.advance(amp, dt, Color(0.8, 0.3, 0.2), 1.0)
		peak = maxf(peak, max_disp(res[Mesh.ARRAY_VERTEX], grid[0][Mesh.ARRAY_VERTEX]))
		if a.state_snapshot() != b.state_snapshot() or a._rng.state != b._rng.state: same = false
	check("deform_equals_advance", same)
	check("draws_consumed", a._rng.state != 1)

	# 10. Sanity on real preset: LVT7 preset 0 (DoAmp/DoHmap/DoMask) with A=1,S=1.
	var c = SuperBump.new()
	c.reset(lvt7, 3)
	c.set_height_map(hm); c.set_mask_map(mk)
	var lvt7_max := 0.0
	var lvt7_nomask := 0.0
	var lvt7_sum_masked := 0.0
	var lvt7_sum_unmasked := 0.0
	var d = SuperBump.new()
	d.reset(lvt7, 3); d.set_height_map(hm)
	for f in range(30):
		var r1: Array = c.deform(grid[0], grid[1], 1.0, 1.0, dt)
		var r2: Array = d.deform(grid[0], grid[1], 1.0, 1.0, dt)
		lvt7_max = maxf(lvt7_max, max_disp(r1[Mesh.ARRAY_VERTEX], grid[0][Mesh.ARRAY_VERTEX]))
		lvt7_nomask = maxf(lvt7_nomask, max_disp(r2[Mesh.ARRAY_VERTEX], grid[0][Mesh.ARRAY_VERTEX]))
		lvt7_sum_masked += sum_disp(r1[Mesh.ARRAY_VERTEX], grid[0][Mesh.ARRAY_VERTEX])
		lvt7_sum_unmasked += sum_disp(r2[Mesh.ARRAY_VERTEX], grid[0][Mesh.ARRAY_VERTEX])
	check("lvt7_displacement", lvt7_nomask > 0.0 and lvt7_max > 0.0, lvt7_nomask)
	check("lvt7_mask_attenuates", lvt7_sum_masked < lvt7_sum_unmasked, [lvt7_sum_masked, lvt7_sum_unmasked])
	# LVT6 preset 0: DoAmp 0 (colour/texture preset) -> no displacement but colours/UVs change.
	var lvt6 := load_preset("res://scenes/lava25/LVT6/defsuperbump.lvd", 0)
	var e = SuperBump.new()
	e.reset(lvt6, 3)
	var lvt6_disp := 0.0; var lvt6_col := 0.0; var lvt6_uv := 0.0
	for f in range(30):
		var r3: Array = e.deform(grid[0], grid[1], 1.0, 1.0, dt, 1.0, Color(0.8, 0.3, 0.2))
		lvt6_disp = maxf(lvt6_disp, max_disp(r3[Mesh.ARRAY_VERTEX], grid[0][Mesh.ARRAY_VERTEX]))
		var cc: PackedColorArray = r3[Mesh.ARRAY_COLOR]
		var uu: PackedVector2Array = r3[Mesh.ARRAY_TEX_UV]
		for i in range(cc.size()):
			lvt6_col = maxf(lvt6_col, absf(cc[i].r-0.8)+absf(cc[i].g-0.3)+absf(cc[i].b-0.2))
			lvt6_uv = maxf(lvt6_uv, (uu[i]-grid[0][Mesh.ARRAY_TEX_UV][i]).length())
	check("lvt6_colour_only", lvt6_disp == 0.0 and lvt6_col > 0.0 and lvt6_uv > 0.0, [lvt6_disp, lvt6_col, lvt6_uv])
	notes = {"equivalence_peak_disp": peak, "lvt7_max_disp_masked": lvt7_max, "lvt7_max_disp_unmasked": lvt7_nomask, "lvt7_sum_masked": lvt7_sum_masked, "lvt7_sum_unmasked": lvt7_sum_unmasked,
		"lvt6_max_colour_delta": lvt6_col, "lvt6_max_uv_delta": lvt6_uv}

	print(JSON.stringify({"passed": failures.is_empty(), "failures": failures, "notes": notes}))
	quit(0 if failures.is_empty() else 1)
