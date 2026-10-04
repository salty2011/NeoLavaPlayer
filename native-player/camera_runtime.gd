extends RefCounted
## Recovered Lava3.dll camera runtime (0x10001000–0x1000148e).
## Scene responsiveness scales elapsed seconds before this helper is called,
## or can be passed to update explicitly. Coordinates remain in original space.

const LegacyRand = preload("res://legacy_rand.gd")
## Original MaxFrameRate default; the A==1 counter is normalised to it.
const COUNTER_REFERENCE_RATE := 60.0
const HYDROID_SETTINGS := {
	"Radius": 7.200360, "RadiusMin": 4.0, "RadiusMax": 8.5, "RadiusMaxD": 2.5,
	"Theta": 97.829872, "ThetaMin": 0.0, "ThetaMax": 360.0, "ThetaMaxD": 40.0,
	"Phi": 66.448807, "PhiMin": 1.0, "PhiMax": 130.0, "PhiMaxD": 2.0,
	"Direction0": 0.961477, "Direction1": 0.240453, "Direction2": -0.133207,
	"MaxMove": 5.0, "Lock": 0.0, "FOV": 45.0, "NearClip": 1.0, "FarClip": 200.0,
}

var radius: float = 15.0
var radius_min: float = 10.0
var radius_max: float = 20.0
var radius_max_delta: float = 2.5
var theta: float = 45.0
var theta_min: float = 0.0
var theta_max: float = 360.0
var theta_max_delta: float = 40.0
var phi: float = 45.0
var phi_min: float = 10.0
var phi_max: float = 80.0
var phi_max_delta: float = 40.0
var direction := Vector3(0.15, -0.1, 0.0)
var max_move: float = 10.0
var locked: bool = false
var scene_style: int = 0
var move_counter: float = 0.0
var fov: float = 45.0
var near_clip: float = 1.0
var far_clip: float = 200.0
## Shared MSVC rand stream (original camera draws rand at 0x100011b3/0x100011ca).
var rand = LegacyRand.new()
## true = original per-update counting (+1 per call, frame-rate dependent).
## false = deliberate deviation: +dt*60, identical to the original at 60 updates/s.
var count_per_update := false

func _init(settings: Dictionary = HYDROID_SETTINGS, style: int = 49) -> void:
	scene_style = style
	configure(settings)

func configure(settings: Dictionary) -> void:
	radius = float(settings.get("Radius", radius))
	radius_min = float(settings.get("RadiusMin", radius_min))
	radius_max = float(settings.get("RadiusMax", radius_max))
	radius_max_delta = float(settings.get("RadiusMaxD", radius_max_delta))
	theta = float(settings.get("Theta", theta))
	theta_min = float(settings.get("ThetaMin", theta_min))
	theta_max = float(settings.get("ThetaMax", theta_max))
	theta_max_delta = float(settings.get("ThetaMaxD", theta_max_delta))
	phi = float(settings.get("Phi", phi))
	phi_min = float(settings.get("PhiMin", phi_min))
	phi_max = float(settings.get("PhiMax", phi_max))
	phi_max_delta = float(settings.get("PhiMaxD", phi_max_delta))
	direction = Vector3(float(settings.get("Direction0", direction.x)), float(settings.get("Direction1", direction.y)), float(settings.get("Direction2", direction.z)))
	max_move = float(settings.get("MaxMove", max_move))
	locked = float(settings.get("Lock", 1.0 if locked else 0.0)) != 0.0
	fov = float(settings.get("FOV", fov))
	near_clip = float(settings.get("NearClip", near_clip))
	far_clip = float(settings.get("FarClip", far_clip))
	move_counter = 0.0

func update(delta_seconds: float, global_s: float, max_band_a: float, responsiveness: float = 1.0) -> Vector3:
	var elapsed: float = delta_seconds * responsiveness
	if elapsed == 0.0 or locked or (scene_style & 0x40) != 0:
		return position()
	# Original (0x10001183) counts update calls with A==1, not seconds or rising
	# edges. Normalised to 60 updates/s here so the trigger rate is render-rate
	# independent; at 60 updates/s (fixed-tick default) the two are identical.
	if max_band_a == 1.0:
		move_counter += 1.0 if count_per_update else delta_seconds * COUNTER_REFERENCE_RATE
	if move_counter >= max_move - 0.000001:
		move_counter = 0.0
		var first: int = rand.rand15()
		set_random_direction(first, rand.rand15())
	var movement: float = global_s * elapsed
	theta += theta_max_delta * direction.x * movement
	phi += phi_max_delta * direction.y * movement
	radius += radius_max_delta * direction.z * movement
	if theta_min == 0.0 and theta_max == 360.0:
		# Original only wraps one turn per update.
		if theta >= 360.0:
			theta -= 360.0
		elif theta < 0.0:
			theta += 360.0
	elif theta < theta_min:
		theta = theta_min
		direction.x = -direction.x
	elif theta > theta_max:
		theta = theta_max
		direction.x = -direction.x
	if phi < phi_min:
		phi = phi_min
		direction.y = -direction.y
	elif phi > phi_max:
		phi = phi_max
		direction.y = -direction.y
	if radius < radius_min:
		radius = radius_min
		direction.z = -direction.z
	elif radius > radius_max:
		radius = radius_max
		direction.z = -direction.z
	return position()

func set_random_direction(first_rand15: int, second_rand15: int) -> void:
	# Constants recovered from 0x100331e8 and 0x100331e4; random implementation differs.
	var azimuth: float = float(first_rand15) * 0.00019175345369149
	var polar: float = float(second_rand15) * 0.000095876726845745
	direction = Vector3(cos(azimuth) * sin(polar), sin(azimuth) * sin(polar), cos(polar))

func position() -> Vector3:
	var t: float = deg_to_rad(theta)
	var p: float = deg_to_rad(phi)
	return Vector3(radius * sin(t) * sin(p), radius * cos(p), radius * cos(t) * sin(p))
