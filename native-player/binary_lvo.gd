extends RefCounted
## Static F/G LVO reader. Preserves legacy winding/coordinates and raw frame matrix.
## Returns error instead of building partial meshes. Packed color is interpreted RGBA;
## channel order and the two extra vertex floats still require renderer parity tests.
func read_file(path: String) -> Dictionary:
	return decode(FileAccess.get_file_as_bytes(path))

func decode(bytes: PackedByteArray) -> Dictionary:
	var offset := 0
	if bytes.size() >= 6 and bytes[0] == 66 and bytes[1] == 77:
		offset = bytes.decode_u32(2)
	if offset < 0 or offset >= bytes.size() or bytes[offset] != 70:
		return {"error": "Not an F/G binary LVO"}
	var name_end := offset + 1
	while name_end < bytes.size() and bytes[name_end] != 0:
		name_end += 1
	var matrix_start := name_end + 1
	var geometry := matrix_start + 64
	if geometry + 17 > bytes.size() or bytes[geometry] != 71:
		return {"error": "Missing frame matrix or G geometry header"}
	var raw_matrix := PackedFloat32Array()
	for i in range(16):
		raw_matrix.append(bytes.decode_float(matrix_start + i * 4))
	var vertex_count := bytes.decode_u32(geometry + 1)
	var face_count := bytes.decode_u32(geometry + 5)
	var arity := bytes.decode_u32(geometry + 9)
	var word_count := bytes.decode_u32(geometry + 13)
	var index_start := geometry + 17
	var vertex_start := index_start + word_count * 4
	if vertex_count == 0 or face_count == 0 or vertex_start + vertex_count * 44 + 6 > bytes.size():
		return {"error": "Invalid geometry counts or truncated vertices"}
	if arity != 0 and (arity < 3 or word_count != face_count * arity):
		return {"error": "Invalid fixed face arity/count"}
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var extra := PackedVector2Array()
	for i in range(vertex_count):
		var v := vertex_start + i * 44
		vertices.append(Vector3(bytes.decode_float(v), bytes.decode_float(v + 4), bytes.decode_float(v + 8)))
		normals.append(Vector3(bytes.decode_float(v + 12), bytes.decode_float(v + 16), bytes.decode_float(v + 20)))
		colors.append(Color(bytes[v + 24] / 255.0, bytes[v + 25] / 255.0, bytes[v + 26] / 255.0, bytes[v + 27] / 255.0))
		uvs.append(Vector2(bytes.decode_float(v + 28), bytes.decode_float(v + 32)))
		extra.append(Vector2(bytes.decode_float(v + 36), bytes.decode_float(v + 40)))
	var triangles := PackedInt32Array()
	var cursor := 0
	var polygons: Array[PackedInt32Array] = []
	for face in range(face_count):
		var n := arity
		if arity == 0:
			if cursor >= word_count:
				return {"error": "Truncated polygon count"}
			n = bytes.decode_u32(index_start + cursor * 4)
			cursor += 1
		if n < 3 or cursor + n > word_count:
			return {"error": "Invalid polygon length"}
		var polygon := PackedInt32Array()
		for j in range(n):
			var index := bytes.decode_u32(index_start + cursor * 4)
			cursor += 1
			if index >= vertex_count:
				return {"error": "Vertex index out of range"}
			polygon.append(index)
		polygons.append(polygon)
		var face_triangles := triangulate(polygon, vertices)
		if face_triangles.is_empty():
			return {"error": "Cannot triangulate polygon"}
		triangles.append_array(face_triangles)
	if cursor != word_count:
		return {"error": "Unused index words"}
	var tail := vertex_start + vertex_count * 44
	if bytes[tail] != 67 or bytes[tail + 5] != 90:
		return {"error": "Missing C/color/Z trailer"}
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = triangles
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {"mesh": mesh, "frame_name": bytes.slice(offset + 1, name_end).get_string_from_ascii(),
		"frame_matrix": raw_matrix, "vertices": vertex_count, "faces": face_count,
		"polygons": polygons, "extra_coordinates": extra, "object_color": bytes.decode_u32(tail + 1),
		"trailing_bytes": bytes.size() - tail - 6}

func triangulate(polygon: PackedInt32Array, vertices: PackedVector3Array) -> PackedInt32Array:
	if polygon.size() == 3:
		return polygon.duplicate()
	# Newell normal provides a stable projection for concave planar polygons.
	var normal := Vector3.ZERO
	for i in range(polygon.size()):
		var a := vertices[polygon[i]]
		var b := vertices[polygon[(i + 1) % polygon.size()]]
		normal += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
	var axis := normal.abs().max_axis_index()
	var projected := PackedVector2Array()
	for index in polygon:
		var v := vertices[index]
		projected.append(Vector2(v.y, v.z) if axis == 0 else (Vector2(v.x, v.z) if axis == 1 else Vector2(v.x, v.y)))
	var local_indices := Geometry2D.triangulate_polygon(projected)
	var result := PackedInt32Array()
	for i in range(0, local_indices.size(), 3):
		var a := polygon[local_indices[i]]
		var b := polygon[local_indices[i + 1]]
		var c := polygon[local_indices[i + 2]]
		if (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]).dot(normal) < 0.0:
			var swap := b
			b = c
			c = swap
		result.append_array(PackedInt32Array([a, b, c]))
	return result
