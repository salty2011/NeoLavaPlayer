extends RefCounted
## Static ports of Lava3 Hydra 0x1001f6b0 and morph mesh 0x10021960.
## Original morph normals are raw area-weighted sums. Renderer normalization is external.

static func from_primitives(vertices: PackedVector3Array, primitives: Array, normalize_output: bool = false) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for primitive in primitives:
		var indices: PackedInt32Array = primitive["indices"]
		var kind := int(primitive.get("kind",0)) # 0 triangles, 1 strip, 2 fan.
		if kind==0:
			for i in range(0,indices.size()-2,3):
				_accumulate(vertices,normals,indices[i],indices[i+1],indices[i+2],1.0)
		elif kind==1:
			for i in range(indices.size()-2):
				_accumulate(vertices,normals,indices[i],indices[i+1],indices[i+2],1.0 if i%2==0 else -1.0)
		elif kind==2:
			for i in range(1,indices.size()-1):
				_accumulate(vertices,normals,indices[0],indices[i],indices[i+1],1.0)
	if normalize_output:
		for i in range(normals.size()): normals[i] = normals[i].normalized()
	return normals

static func _accumulate(vertices: PackedVector3Array, normals: PackedVector3Array, a: int, b: int, c: int, sign_value: float) -> void:
	if a<0 or b<0 or c<0 or a>=vertices.size() or b>=vertices.size() or c>=vertices.size(): return
	var normal := (vertices[b]-vertices[a]).cross(vertices[c]-vertices[a])*sign_value
	normals[a] += normal
	normals[b] += normal
	normals[c] += normal

static func hydra_grid(vertices: PackedVector3Array, nx: int, ny: int, direction: float = -1.0) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	if nx<2 or ny<2 or vertices.size()!=(nx+1)*(ny+1): return normals
	var stride := nx+1
	for row in range(1,ny):
		for column in range(1,nx):
			var index := row*stride+column
			normals[index] = _cross(vertices[index]-vertices[index-stride],vertices[index]-vertices[index-1],direction)
	for row in range(1,ny):
		var end := row*stride+nx
		normals[end] = _cross(vertices[end]-vertices[end-stride-1],vertices[end]-vertices[end-1],direction)
		var start := row*stride
		if vertices[start].distance_squared_to(vertices[end])<0.009999999776482582:
			normals[start] = normals[end]
		else:
			normals[start] = _cross(vertices[start]-vertices[start+1],vertices[start]-vertices[start-stride+1],direction)
	for column in range(1,nx):
		var end := ny*stride+column
		normals[end] = _cross(vertices[end]-vertices[end-stride],vertices[end]-vertices[end-stride-1],direction)
		var start := column
		if vertices[start].distance_squared_to(vertices[end])<0.009999999776482582:
			normals[start] = normals[end]
		else:
			normals[start] = _cross(vertices[start]-vertices[start+stride-1],vertices[start]-vertices[start+stride],direction)
	# Original corners copy diagonally adjacent interior normals.
	normals[0] = normals[stride+1]
	normals[nx] = normals[stride+nx-1]
	normals[ny*stride] = normals[(ny-1)*stride+1]
	normals[ny*stride+nx] = normals[(ny-1)*stride+nx-1]
	return normals

static func _cross(first: Vector3, second: Vector3, direction: float) -> Vector3:
	var normal := first.cross(second)
	# Original divides by zero for collapsed cap triangles; finite zero is the port safeguard.
	return normal.normalized()*direction if normal.length_squared()>0.0 else Vector3.ZERO
