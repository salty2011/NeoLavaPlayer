extends RefCounted
## Static Hydroid preset geometry recovered from Lava3.dll 0x1001eed0.
## RuntimeAmplitude is a supplied motion-state snapshot (neutral default 0).
## Frame state is supplied by HydraMotion; original grid normals use LegacyNormals.
const LegacyNormals = preload("res://legacy_normals.gd")

var _preset: Dictionary
var _level: int
var _depth: int
var _rotation_basis: Basis
var _vertices: PackedVector3Array
var _uvs: PackedVector2Array
var _indices: PackedInt32Array
var _branches: Array[Dictionary] = []
var _position_grids: Dictionary = {}
var _grid_size := Vector2i.ZERO

func mesh_from_preset(preset: Dictionary) -> ArrayMesh:
	_preset = preset
	_level = 0
	_depth = 0
	_rotation_basis = Basis.IDENTITY
	_vertices = PackedVector3Array()
	_uvs = PackedVector2Array()
	_indices = PackedInt32Array()
	_branches.clear()
	var dimensions := Vector2i(int(_value("VerticesX",0)),int(_value("VerticesY",0)))
	if dimensions!=_grid_size:
		_position_grids.clear()
		_grid_size = dimensions
	var mesh := ArrayMesh.new()
	if int(_value("VerticesX", 0)) < 3 or int(_value("VerticesY", 0)) < 1:
		return mesh
	if int(_value("SpawnFrequency", 0)) < 1 or int(_value("MaxDepth", 0)) < 1:
		return mesh
	_generate(float(_value("TreeSize", 0.25)), Transform3D.IDENTITY)
	if _indices.is_empty():
		return mesh
	var normals := PackedVector3Array()
	normals.resize(_vertices.size())
	for branch in _branches:
		var grid: PackedVector3Array = branch["grid"]
		var mapping: PackedInt32Array = branch["mapping"]
		var branch_normals := LegacyNormals.hydra_grid(grid,dimensions.x,dimensions.y,float(_value("NormalDirection",-1.0)))
		for i in range(mapping.size()):
			if mapping[i]>=0: normals[mapping[i]] = branch_normals[i]
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(_vertices.size()):
		surface.set_uv(_uvs[i])
		surface.set_normal(normals[i])
		surface.add_vertex(_vertices[i])
	for index in _indices:
		surface.add_index(index)
	return surface.commit()

func mesh_from_frame_snapshot(preset: Dictionary, state_y: float = 0.0, state_z: float = 0.0, bend_amplitude: float = 0.0) -> ArrayMesh:
	# Lava3.dll frame routine 0x1001e4fd..0x1001e535 overwrites translations.
	# Supplied states are controlled inputs, not recovered startup/audio values.
	var snapshot = preset.duplicate()
	snapshot["TranslationX"] = 0.0
	snapshot["TranslationY"] = 0.03999999910593033 * state_y + 0.07999999821186066
	snapshot["TranslationZ"] = 0.009999999776482582 * state_z
	snapshot["RuntimeAmplitude"] = bend_amplitude
	return mesh_from_preset(snapshot)

func _value(key: String, fallback: Variant) -> Variant:
	return _preset.get(key, fallback)

func _rotation(degrees: float) -> Basis:
	var depth_fraction := float(_depth) / float(_value("MaxDepth", 3))
	return Basis(Vector3.ONE.normalized(), degrees * 0.01745329238474369 * pow(depth_fraction, 3.0))

func _generate(radius: float, inherited: Transform3D) -> void:
	var threshold := float(_value("SzThresh", 0.01))
	if radius < threshold or _depth > int(_value("MaxDepth", 3)):
		return
	_level += 1
	var max_level := int(_value("MaxLevel", 12))
	if _level > max_level:
		_level = max_level
		return
	var branch_id := _level
	var transform := inherited
	var vx := int(_value("VerticesX", 9))
	var vy := int(_value("VerticesY", 24))
	var scale_factor := float(_value("ScaleFactor", 0.9))
	var grid: PackedVector3Array = _position_grids.get(branch_id,PackedVector3Array())
	grid.resize((vx+1)*(vy+1))
	var mapping := PackedInt32Array()
	mapping.resize(grid.size())
	mapping.fill(-1)
	var branch := {"grid":grid,"mapping":mapping}
	_branches.append(branch)
	_position_grids[branch_id] = grid
	var previous_ring := -1
	for segment in range(vy + 1):
		if segment == 0 and branch_id != 1:
			transform.basis = transform.basis * Basis(Vector3.UP, float(branch_id) * 40.0)
			_rotation_basis = _rotation(float(_value("BranchRotation", 0.0)))
			transform.basis = transform.basis * _rotation_basis
			_rotation_basis = _rotation(float(_value("Rotation", 0.0)))
		if radius * scale_factor < threshold or segment == vy:
			radius = 0.0
		var ring_start := _vertices.size()
		for i in range(vx + 1):
			var angle := float(i) / float(vx) * 6.2831854820251465
			var point := transform * Vector3(radius * sin(angle), 0.0, radius * cos(angle))
			var grid_index := segment*(vx+1)+i
			grid[grid_index] = point
			mapping[grid_index] = _vertices.size()
			_vertices.append(point)
			# Original UV routine 0x1001fee0: u starts at 0, v at 1;
			# repeat products / NX and NY advance each ring's coordinates.
			_uvs.append(Vector2(float(i) / vx * float(_value("TexRepeatX", 1.0)) * float(_value("TexRepeatXScale", 1.0)), 1.0 - float(segment) / vy * float(_value("TexRepeatY", 1.0)) * float(_value("TexRepeatYScale", 1.0))))
		if previous_ring >= 0:
			for i in range(vx):
				# Modern triangle tessellation of the original adjacent-ring strip.
				_indices.append_array(PackedInt32Array([previous_ring+i, ring_start+i, previous_ring+i+1, previous_ring+i+1, ring_start+i, ring_start+i+1]))
		previous_ring = ring_start
		radius *= scale_factor
		if radius < threshold:
			branch["grid"] = grid
			branch["mapping"] = mapping
			_position_grids[branch_id] = grid
			return
		if segment % int(_value("SpawnFrequency", 2)) == 0 and segment >= int(_value("SpawnStart", 4)):
			_depth += 1
			_generate(radius, transform)
			_depth -= 1
		var translation := Vector3(float(_value("TranslationX", 0.0)), float(_value("TranslationY", 0.0)), float(_value("TranslationZ", -0.7)))
		transform.origin += transform.basis * translation * scale_factor
		transform.basis = transform.basis * _rotation_basis
		var bend := cos(float(segment) * 31.41592788696289 / float(vy)) * float(_value("RuntimeAmplitude", 0.0)) * 0.01745329238474369
		# Original alternates Y (segment divisible by 3) and Z bend matrices.
		transform.basis = transform.basis * Basis(Vector3.UP if segment % 3 == 0 else Vector3.BACK, bend)

	branch["grid"] = grid
	branch["mapping"] = mapping
	_position_grids[branch_id] = grid
