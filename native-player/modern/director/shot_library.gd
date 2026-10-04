extends RefCounted
## Shot library for the Modern virtual director (Phase 4d). A shot is a pose
## function of shot time: pose(shot, u, ctx) -> {position, target, fov, focus,
## subject}. Shots are defined in profile data (modern/profiles/<scene>.json,
## "director.shots") relative to scene objects (by name) and the scene centre,
## then resolved once per use with the director's seeded random draws
## (resolve()). See docs/DIRECTOR_AND_ANIMATION.md.
##
## Types:
##   original  the recovered Lava3 camera (the soul): its own position, LookAt and FOV
##   orbit     around a target at distance/elevation, azimuth advancing at az_speed (deg/s)
##             (wide establishing shots are slow orbits with a wide FOV)
##   closeup   on one object: camera outside it (away from the scene centre), slow drift
##   dolly     distance moves from -> to over travel_bars (smoothstep), slight orbit
##   crane     elevation moves from -> to over travel_bars (smoothstep), slight orbit
##   handheld  fixed framing plus low-amplitude seeded noise on position and aim

const TYPES := ["original", "orbit", "closeup", "dolly", "crane", "handheld"]

## Uniform draw in [a, b] for a [a, b] array, or the value itself.
static func _range(value, r: float) -> float:
	if value is Array and value.size() >= 2: return lerpf(float(value[0]), float(value[1]), r)
	return float(value)

## Resolve a shot definition into a concrete shot instance. rand is a
## Callable(salt: int) -> float in [0, 1). from_azimuth (deg) is the current
## view azimuth around the target, used for the 30-degree rule on cuts.
static func resolve(definition: Dictionary, rand: Callable, bar_seconds: float, from_azimuth: float, min_turn: float, max_turn: float = 170.0) -> Dictionary:
	var shot := definition.duplicate(true)
	shot.type = str(definition.get("type", "orbit"))
	shot.target = str(definition.get("target", "@center"))
	shot.distance = _range(definition.get("distance", 6.0), rand.call(1))
	shot.elevation = _range(definition.get("elevation", 15.0), rand.call(2))
	var direction := -1.0 if rand.call(3) < 0.5 else 1.0
	shot.az_speed = _range(definition.get("az_speed", 0.0), rand.call(4)) * direction
	shot.fov = float(definition.get("fov", 45.0))
	shot.look_offset = float(definition.get("look_offset", 0.0))
	shot.travel = float(definition.get("travel_bars", 8.0)) * bar_seconds
	shot.from = _range(definition.get("from", shot.distance if shot.type == "dolly" else shot.elevation), rand.call(5))
	shot.to = _range(definition.get("to", shot.from), rand.call(6))
	shot.noise = float(definition.get("noise", 0.0))
	shot.noise_aim = float(definition.get("noise_aim", shot.noise * 0.5))
	shot.noise_freq = float(definition.get("noise_freq", 0.5))
	shot.noise_seed = int(rand.call(7) * 100000.0)
	if shot.type == "closeup":
		# Azimuth relative to the target's outward direction from the centre.
		shot.azimuth = _range(definition.get("az_offset", 0.0), rand.call(8))
	else:
		# 30-degree rule: a new framing turns at least min_turn from the last.
		var turn := lerpf(min_turn, maxf(max_turn, min_turn), rand.call(8)) * (-1.0 if rand.call(9) < 0.5 else 1.0)
		shot.azimuth = from_azimuth + turn if definition.get("azimuth") == null else _range(definition.get("azimuth"), rand.call(8))
	return shot

static func _spherical(azimuth_deg: float, elevation_deg: float, distance: float) -> Vector3:
	var az := deg_to_rad(azimuth_deg)
	var el := deg_to_rad(elevation_deg)
	return Vector3(cos(el) * sin(az), sin(el), cos(el) * cos(az)) * distance

## Smooth 1D value noise in [-1, 1] (cubic-interpolated hashed lattice).
static func noise1(x: float, noise_seed: int) -> float:
	var i := int(floor(x))
	var f := x - float(i)
	var a := _hash(i, noise_seed)
	var b := _hash(i + 1, noise_seed)
	var s := f * f * (3.0 - 2.0 * f)
	return lerpf(a, b, s)

static func _hash(i: int, salt: int) -> float:
	var h: int = (i * 73856093) ^ (salt * 19349663) ^ 0x5bd1e995
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xffff) / 32767.5 - 1.0

## Target point of a shot: "@center" or an object's live centre.
static func target_point(shot: Dictionary, ctx: Dictionary) -> Vector3:
	var name := str(shot.get("target", "@center"))
	var targets: Dictionary = ctx.get("targets", {})
	if name != "@center" and targets.has(name): return targets[name]
	return ctx.get("center", Vector3.ZERO)

## Pose at shot time u (seconds, already pace-scaled by the director).
## ctx: {center, targets{name: Vector3}, original{position, target, fov}, push 0..1}.
static func pose(shot: Dictionary, u: float, ctx: Dictionary) -> Dictionary:
	var push := float(ctx.get("push", 0.0))
	var kind := str(shot.get("type", "orbit"))
	if kind == "original":
		var original: Dictionary = ctx.get("original", {})
		var o_target: Vector3 = original.get("target", Vector3.ZERO)
		var o_position: Vector3 = original.get("position", Vector3(0, 0, 6))
		return {"position": o_target + (o_position - o_target) * (1.0 - push), "target": o_target,
			"fov": float(original.get("fov", 45.0)), "focus": -1.0, "subject": ""}
	var target := target_point(shot, ctx) + Vector3(0, float(shot.get("look_offset", 0.0)), 0)
	var distance := float(shot.distance)
	var elevation := float(shot.elevation)
	var azimuth := float(shot.azimuth) + float(shot.az_speed) * u
	match kind:
		"closeup":
			var center: Vector3 = ctx.get("center", Vector3.ZERO)
			var outward := Vector3(target.x - center.x, 0.0, target.z - center.z)
			var base_az := rad_to_deg(atan2(outward.x, outward.z)) if outward.length_squared() > 1e-6 else 0.0
			azimuth = base_az + float(shot.azimuth) + float(shot.az_speed) * u
		"dolly":
			distance = lerpf(float(shot.from), float(shot.to), smoothstep(0.0, 1.0, u / maxf(float(shot.travel), 0.1)))
		"crane":
			elevation = lerpf(float(shot.from), float(shot.to), smoothstep(0.0, 1.0, u / maxf(float(shot.travel), 0.1)))
	distance *= 1.0 - push * float(shot.get("push_scale", 1.0))
	var position := target + _spherical(azimuth, elevation, distance)
	var aim := target
	if kind == "handheld" and float(shot.noise) > 0.0:
		var t := u * float(shot.noise_freq)
		var s := int(shot.noise_seed)
		position += Vector3(noise1(t, s), noise1(t + 17.3, s) * 0.6, noise1(t + 41.9, s)) * float(shot.noise) * float(ctx.get("noise_gain", 1.0))
		aim += Vector3(noise1(t * 0.8 + 5.1, s + 1), noise1(t * 0.8 + 9.7, s + 1), noise1(t * 0.8 + 3.3, s + 1)) * float(shot.noise_aim) * float(ctx.get("noise_gain", 1.0))
	return {"position": position, "target": aim, "fov": float(shot.fov),
		"focus": position.distance_to(target) if kind == "closeup" else -1.0,
		"subject": str(shot.get("target", "")) if kind == "closeup" else ""}

## Glide between two poses around a centre: azimuth (shortest way), elevation
## and distance are interpolated, so the camera travels around the scene
## instead of through it. g in 0..1.
static func glide(from: Dictionary, to: Dictionary, g: float, center: Vector3) -> Dictionary:
	var a: Vector3 = Vector3(from.position) - center
	var b: Vector3 = Vector3(to.position) - center
	var ra := maxf(a.length(), 1e-4)
	var rb := maxf(b.length(), 1e-4)
	var az_a := atan2(a.x, a.z)
	var az_b := atan2(b.x, b.z)
	var el_a := asin(clampf(a.y / ra, -1.0, 1.0))
	var el_b := asin(clampf(b.y / rb, -1.0, 1.0))
	var az := az_a + wrapf(az_b - az_a, -PI, PI) * g
	var el := lerpf(el_a, el_b, g)
	var r := lerpf(ra, rb, g)
	var out := to.duplicate()
	out.position = center + Vector3(cos(el) * sin(az), sin(el), cos(el) * cos(az)) * r
	out.target = Vector3(from.target).lerp(to.target, g)
	out.fov = lerpf(float(from.fov), float(to.fov), g)
	return out

## View azimuth (deg) of a camera position around a target, for the 30-degree rule.
static func azimuth_of(position: Vector3, target: Vector3) -> float:
	var d := position - target
	return rad_to_deg(atan2(d.x, d.z))
