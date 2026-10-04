extends RefCounted
## Original Lava3.dll coordinate/normal/UV equations with modern triangle tessellation.
## SPHERE 0x10023b30, CYLINDER 0x10023dd0, TORUS 0x100240a0,
## SHEET 0x10024350, DISK 0x10024590. BLOB is a separate unsupported system.
var source := ""
var last_error := ""
const SUPPORTED := ["SPHERE", "TORUS", "CYLINDER", "SHEET", "DISK"]

func definition(filename: String) -> Dictionary:
	return read_definition(source.path_join(filename))

func read_definition(path: String) -> Dictionary:
	return decode_definition(FileAccess.get_file_as_bytes(path))

func decode_definition(bytes: PackedByteArray) -> Dictionary:
	var offset := 0
	if bytes.size() >= 6 and bytes[0] == 66 and bytes[1] == 77: offset = bytes.decode_u32(2)
	if offset < 0 or offset >= bytes.size(): return {"error": "Invalid LVO payload offset"}
	var text := bytes.slice(offset).get_string_from_ascii().replace("\\r", "").replace("\\n", "\n").replace("\r", "")
	var lines := text.split("\n", false)
	if lines.is_empty() or not lines[0].to_upper().begins_with("PARAMETRIC "):
		return {"error": "Not a PARAMETRIC definition"}
	var result := {"kind": lines[0].strip_edges().substr(11).to_upper(), "payload_offset": offset, "raw_source": text,
		"TexRepX": 1.0, "TexRepY": 1.0, "TexCentX": 0.0, "TexCentY": 0.0, "Inside": 0.0, "WrapTheta": 0.0, "WrapPhi": 0.0, "R3": 0.0}
	var names := {"nx": "NX", "ny": "NY", "thetamin": "ThetaMin", "thetamax": "ThetaMax", "phimin": "PhiMin", "phimax": "PhiMax", "inside": "Inside", "wraptheta": "WrapTheta", "wrapphi": "WrapPhi", "r1": "R1", "r2": "R2", "r3": "R3", "texrepx": "TexRepX", "texrepy": "TexRepY", "texcentx": "TexCentX", "texcenty": "TexCentY"}
	result.unknown_fields = []
	for line in lines.slice(1):
		var words := line.split(";")[0].replace("\t", " ").split(" ", false)
		if words.size() < 2: continue
		if names.has(words[0].to_lower()) and words[1].is_valid_float(): result[names[words[0].to_lower()]] = float(words[1])
		else: result.unknown_fields.append(line)
	var problem := validate_definition(result)
	if not problem.is_empty(): result.error = problem
	return result

func validate_definition(d: Dictionary) -> String:
	if d.has("error"): return d.error
	if not SUPPORTED.has(d.get("kind", "")): return "Unsupported parametric kind: " + str(d.get("kind", ""))
	for key in ["NX", "NY", "R1"]:
		if not d.has(key): return "Missing parametric field: " + key
	if d.kind in ["TORUS", "CYLINDER", "SHEET", "DISK"] and not d.has("R2"): return "Missing R2"
	if d.kind == "CYLINDER" and is_zero_approx(float(d.get("R3", 0))): return "Cylinder R3 cannot be zero"
	if int(d.NX) <= 0 or int(d.NY) <= 0 or (int(d.NX) + 1) * (int(d.NY) + 1) > 1000000: return "Invalid parametric grid dimensions"
	for key in d:
		if d[key] is float and not is_finite(d[key]): return "Non-finite field: " + key
	return ""

func sample(d: Dictionary, u: float, v: float) -> Dictionary:
	var theta := deg_to_rad(lerp(float(d.get("ThetaMin", 0)), float(d.get("ThetaMax", 360)), u))
	var phi := deg_to_rad(lerp(float(d.get("PhiMin", 0)), float(d.get("PhiMax", 180)), v))
	var position := Vector3.ZERO
	var normal := Vector3.ZERO
	var radius := float(d.R1)
	var inside := int(d.get("Inside", 0)) == 1
	var tex_x := float(d.get("TexRepX", 1))
	var tex_y := float(d.get("TexRepY", 1))
	var center_x := float(d.get("TexCentX", 0))
	var center_y := float(d.get("TexCentY", 0))
	var uv := Vector2((1.0 - u if inside else u) * tex_x + center_x, (1.0 - v) * tex_y + center_y)
	match d.kind:
		"SPHERE":
			normal = Vector3(-sin(phi) * sin(theta), cos(phi), -sin(phi) * cos(theta))
			position = radius * normal
		"TORUS":
			normal = Vector3(-sin(phi) * sin(theta), cos(phi), -sin(phi) * cos(theta))
			position = Vector3(-(radius + float(d.R2) * sin(phi)) * sin(theta), float(d.R2) * cos(phi), -(radius + float(d.R2) * sin(phi)) * cos(theta))
		"CYLINDER":
			var slope := (float(d.R2) - radius) / (2.0 * float(d.R3))
			radius = lerp(radius, float(d.R2), v)
			position = Vector3(-radius * sin(theta), float(d.R3) * (1.0 - 2.0 * v), -radius * cos(theta))
			normal = Vector3(-sin(theta), slope, -cos(theta)).normalized()
		"SHEET":
			position = Vector3(radius * (2.0 * u - 1.0), float(d.R2) * (1.0 - 2.0 * v), 0)
			normal = Vector3(0, 0, 1)
		"DISK":
			radius = lerp(radius, float(d.R2), v)
			position = Vector3(-radius * sin(theta), 0, -radius * cos(theta))
			normal = Vector3.UP
			# Original special R3=-1 branch normalizes by the current radial row.
			# Recovered planar disks use NY=1: center/outer perimeter UV mapping.
			if float(d.get("R3", 0)) == -1.0:
				var factor := 0.5 / radius if radius != 0.0 else 0.0
				uv = Vector2(position.x * factor * tex_x + center_x + 0.5, position.z * factor * tex_y * (1.0 if inside else -1.0) + center_y + 0.5)
	return {"position": position, "normal": -normal if inside else normal, "uv": uv}

func mesh_for(d: Dictionary) -> ArrayMesh:
	last_error = validate_definition(d)
	if not last_error.is_empty(): return null
	var nx := int(d.NX)
	var ny := int(d.NY)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for y in range(ny + 1):
		for x in range(nx + 1):
			var point := sample(d, float(x) / nx, float(y) / ny)
			vertices.append(point.position)
			normals.append(point.normal)
			uvs.append(point.uv)
	for y in range(ny):
		for x in range(nx):
			var a := y * (nx + 1) + x
			var face := PackedInt32Array([a, a + 1, a + nx + 1, a + 1, a + nx + 2, a + nx + 1])
			if int(d.get("Inside", 0)) == 1:
				face = PackedInt32Array([a, a + nx + 1, a + 1, a + 1, a + nx + 1, a + nx + 2])
			indices.append_array(face)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
