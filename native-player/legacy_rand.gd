extends RefCounted
## MSVC multithreaded rand() as used by Lava3.dll (0x10028250):
## holdrand = holdrand * 214013 + 2531011; return (holdrand >> 16) & 0x7fff.
## Lava3.dll never calls srand, so the original stream starts at seed 1 and is
## shared by every consumer on the engine thread. See
## research/oozic/original-player-capability-audit.md section 6.
var state := 1

func _init(seed_value: int = 1): state = seed_value

func reseed(seed_value: int = 1): state = seed_value

func rand15() -> int:
	state = (state * 214013 + 2531011) & 0xffffffff
	return (state >> 16) & 32767

## rand()/32767, the RandRange/RandInt scale (0..1 inclusive).
func unit() -> float:
	return float(rand15()) * 0.000030518509447574615
