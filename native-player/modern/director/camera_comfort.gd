extends RefCounted
## Comfort rig for the virtual director (Phase 4d). Follows the director's
## target pose with a critically damped spring and hard caps, so moves glide
## and nothing lurches:
##   - linear speed and acceleration caps (scene units/s, /s^2)
##   - angular speed and acceleration caps on the view direction (deg/s, /s^2)
##   - FOV speed cap (deg/s)
##   - no roll (the caller aims with world up; elevation is clamped below the pole)
##   - collision: the camera is kept outside obstacle spheres/boxes (grown by
##     the near clip plus a margin) and inside the scene bounds, resolved inside
##     the integrator so the velocity slides along the obstacle instead of popping.
## Integration runs on a fixed 240 Hz grid of the director clock and the output
## is interpolated between the last two substeps, so the path is the same at
## 30, 60 or 144 fps (docs/FRAME_TIMING.md uses the same pattern for the sim).

const RATE := 240.0
const MAX_CATCHUP := 48

var max_speed := 3.5
var max_accel := 4.0
var max_angular_speed := deg_to_rad(50.0)
var max_angular_accel := deg_to_rad(90.0)
var max_fov_speed := 15.0
## Spring frequency (rad/s); the director lowers it in calm sections.
var omega := 2.2
## Obstacles: {"spheres": [{center, radius}], "boxes": [AABB], "center", "max_radius", "min_y", "max_y"}.
var guard: Dictionary = {}

var _clock := 0.0
var _ticks := 0
var _has_state := false
var _p := Vector3.ZERO
var _v := Vector3.ZERO
var _q := Vector3.ZERO
var _w := Vector3.ZERO
var _f := 45.0
var _fv := 0.0
var _ang := 0.0
var _prev := {}
var _last_target := {}
## Last frame's output (for tests and the overlay).
var output := {}

func configure(settings: Dictionary) -> void:
	max_speed = float(settings.get("max_speed", max_speed))
	max_accel = float(settings.get("max_accel", max_accel))
	max_angular_speed = deg_to_rad(float(settings.get("max_angular_speed_deg", rad_to_deg(max_angular_speed))))
	max_angular_accel = deg_to_rad(float(settings.get("max_angular_accel_deg", rad_to_deg(max_angular_accel))))
	max_fov_speed = float(settings.get("max_fov_speed", max_fov_speed))

## Jump straight to a pose (a cut): no velocity carried over.
func snap(pose: Dictionary) -> void:
	_p = resolve_position(pose.position)
	_q = pose.target
	_f = float(pose.fov)
	_v = Vector3.ZERO
	_w = Vector3.ZERO
	_fv = 0.0
	_ang = 0.0
	_has_state = true
	_prev = _state()
	output = _state()
	_last_target = {"position": pose.position, "target": pose.target, "fov": float(pose.fov)}

func is_ready() -> bool: return _has_state

func _state() -> Dictionary:
	return {"position": _p, "target": _q, "fov": _f}

## Advance by dt toward target (a pose dict) and return the interpolated pose.
func step(target: Dictionary, dt: float) -> Dictionary:
	if not _has_state: snap(target)
	var start := _clock
	_clock += maxf(dt, 0.0)
	var due := int(floor(_clock * RATE + 1e-7)) - _ticks
	if due > MAX_CATCHUP:
		_ticks += due - MAX_CATCHUP
		due = MAX_CATCHUP
	var h := 1.0 / RATE
	var from: Dictionary = _last_target if not _last_target.is_empty() else target
	for i in due:
		_prev = _state()
		# First-order hold: the target moves linearly across this frame's substeps,
		# so the path barely depends on the render rate.
		var f := clampf((float(_ticks + 1) / RATE - start) / dt, 0.0, 1.0) if dt > 0.0 else 1.0
		var goal := {"position": Vector3(from.position).lerp(target.position, f), "target": Vector3(from.target).lerp(target.target, f),
			"fov": lerpf(float(from.fov), float(target.fov), f)}
		_substep(goal, h)
		_ticks += 1
	_last_target = {"position": target.position, "target": target.target, "fov": float(target.fov)}
	var alpha := clampf(_clock * RATE - float(_ticks), 0.0, 1.0)
	var now := _state()
	output = {"position": Vector3(_prev.position).lerp(now.position, alpha), "target": Vector3(_prev.target).lerp(now.target, alpha),
		"fov": lerpf(float(_prev.fov), float(now.fov), alpha)}
	return output

func _spring(x: Vector3, v: Vector3, goal: Vector3, h: float, accel_cap: float, speed_cap: float) -> Array:
	var a := (goal - x) * omega * omega - v * 2.0 * omega
	if a.length() > accel_cap: a = a.normalized() * accel_cap
	v += a * h
	if v.length() > speed_cap: v = v.normalized() * speed_cap
	return [x + v * h, v]

func _substep(target: Dictionary, h: float) -> void:
	var old_dir := (_q - _p).normalized()
	var moved := _spring(_p, _v, target.position, h, max_accel, max_speed)
	_p = moved[0]
	_v = moved[1]
	# Collision: resolve, then drop the velocity component into the obstacle.
	var resolved := resolve_position(_p)
	if resolved != _p:
		var push := resolved - _p
		var normal := push.normalized()
		_v -= normal * minf(_v.dot(normal), 0.0)
		_p = resolved
	var aimed := _spring(_q, _w, target.target, h, max_accel * 1.5, max_speed * 1.5)
	var q: Vector3 = aimed[0]
	_w = aimed[1]
	# Angular caps on the view direction (speed, then acceleration).
	var new_dir := (q - _p).normalized()
	var angle := old_dir.angle_to(new_dir) if old_dir.length_squared() > 0.5 else 0.0
	var allowed := minf(max_angular_speed, _ang + max_angular_accel * h) * h
	if angle > allowed and angle > 1e-9:
		var axis := old_dir.cross(new_dir)
		if axis.length_squared() > 1e-12:
			new_dir = old_dir.rotated(axis.normalized(), allowed)
			q = _p + new_dir * (q - _p).length()
		angle = allowed
	_ang = angle / h
	_w = (q - _q) / h
	_q = q
	# FOV.
	var df := clampf(float(target.fov) - _f, -max_fov_speed * h, max_fov_speed * h)
	_f += df

## Keep a camera position out of geometry and inside the scene bounds.
func resolve_position(p: Vector3) -> Vector3:
	if guard.is_empty(): return p
	var center: Vector3 = guard.get("center", Vector3.ZERO)
	var max_radius := float(guard.get("max_radius", INF))
	var offset := p - center
	if offset.length() > max_radius: p = center + offset.normalized() * max_radius
	p.y = clampf(p.y, float(guard.get("min_y", -INF)), float(guard.get("max_y", INF)))
	for box in guard.get("boxes", []):
		var b: AABB = box
		if b.has_point(p):
			# Smallest way out; upward exits are preferred (looking down is calmer).
			var exits := [
				[b.end.y - p.y, Vector3(p.x, b.end.y, p.z)],
				[(p.y - b.position.y) * 1.5, Vector3(p.x, b.position.y, p.z)],
				[b.end.x - p.x, Vector3(b.end.x, p.y, p.z)],
				[p.x - b.position.x, Vector3(b.position.x, p.y, p.z)],
				[b.end.z - p.z, Vector3(p.x, p.y, b.end.z)],
				[p.z - b.position.z, Vector3(p.x, p.y, b.position.z)],
			]
			exits.sort_custom(func(a, c): return a[0] < c[0])
			p = exits[0][1]
	for sphere in guard.get("spheres", []):
		var c: Vector3 = sphere.center
		var r := float(sphere.radius)
		var d := p - c
		if d.length() < r:
			p = c + (d.normalized() if d.length_squared() > 1e-9 else Vector3.UP) * r
	return p

## True if p violates the guard (for tests).
func inside_geometry(p: Vector3, tolerance := 1e-3) -> bool:
	for box in guard.get("boxes", []):
		if AABB(box.position + Vector3.ONE * tolerance, box.size - Vector3.ONE * tolerance * 2.0).has_point(p): return true
	for sphere in guard.get("spheres", []):
		if p.distance_to(sphere.center) < float(sphere.radius) - tolerance: return true
	return false
