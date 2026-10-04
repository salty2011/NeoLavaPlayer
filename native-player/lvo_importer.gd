extends RefCounted
# Procedural sphere/torus coordinates and UV conventions recovered from
# Lava3.dll 0x10023b30 and 0x100240a0; modern triangle tessellation.
var source: String
func definition(filename):
	var b = FileAccess.get_file_as_bytes(source + filename)
	assert(b[0] == 66 and b[1] == 77)
	var offset = b.decode_u32(2)
	var lines = b.slice(offset).get_string_from_ascii().split("\n", false)
	var d = {"kind": lines[0].strip_edges().trim_prefix("PARAMETRIC ")}
	for line in lines.slice(1):
		var parts = line.strip_edges().split("\t", false)
		if parts.size() >= 2: d[parts[0]] = float(parts[1].strip_edges().split(";")[0])
	return d
func mesh_for(d):
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()
	var indices = PackedInt32Array()
	var nx = int(d.NX)
	var ny = int(d.NY)
	for y in range(ny+1):
		for x in range(nx+1):
			var u = float(x)/nx
			var v = float(y)/ny
			var theta = deg_to_rad(lerp(d.ThetaMin, d.ThetaMax, u))
			var phi = deg_to_rad(lerp(d.PhiMin, d.PhiMax, v))
			var n: Vector3
			var p: Vector3
			if d.kind == "SPHERE":
				n = Vector3(-sin(phi)*sin(theta), cos(phi), -sin(phi)*cos(theta))
				p = d.R1*n
			else:
				n = Vector3(-sin(phi)*sin(theta), cos(phi), -sin(phi)*cos(theta))
				p = Vector3(-(d.R1+d.R2*sin(phi))*sin(theta),d.R2*cos(phi),-(d.R1+d.R2*sin(phi))*cos(theta))
			vertices.append(p)
			normals.append(n * (-1.0 if d.Inside else 1.0))
			uvs.append(Vector2((1.0-u if d.Inside else u)*d.get("TexRepX",1.0),(1.0-v)*d.get("TexRepY",1.0)))
	for y in range(ny):
		for x in range(nx):
			var a = y*(nx+1)+x
			indices.append_array(PackedInt32Array([a,a+1,a+nx+1,a+1,a+nx+2,a+nx+1]))
	var arrays=[]
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices
	arrays[Mesh.ARRAY_NORMAL]=normals
	arrays[Mesh.ARRAY_TEX_UV]=uvs
	arrays[Mesh.ARRAY_INDEX]=indices
	var mesh=ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return mesh
