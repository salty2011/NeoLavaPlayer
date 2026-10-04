extends RefCounted
## Queue navigation is independent of decoding: commit only after a track loads.
enum Repeat { OFF, ALL, ONE }
var shuffle := false
var repeat_mode := Repeat.ALL
var current := -1
var count := 0
var bag: Array[int] = []
var history: Array[int] = []
var visited: Array[int] = []
## Indices that failed to decode; skipped by next_index until they load again.
var failed: Array[int] = []
var rng := RandomNumberGenerator.new()

func _init(): rng.randomize()

func configure(size: int):
	count = size
	bag.clear()
	visited.clear()
	if current >= 0 and current < size: visited.append(current)
	if current >= count: current = -1
	history = history.filter(func(index): return index < count)
	failed = failed.filter(func(index): return index < count)

func set_shuffle(enabled: bool):
	shuffle = enabled
	bag.clear()

func next_index(finished := false) -> int:
	if count == 0: return -1
	if finished and repeat_mode == Repeat.ONE and current >= 0: return current
	if current < 0: return 0
	if shuffle:
		for index in failed: bag.erase(index)
		if bag.is_empty():
			if repeat_mode == Repeat.OFF and visited.size() + _unvisited_failures() >= count: return -1
			for index in count:
				if index != current and not failed.has(index) and (repeat_mode != Repeat.OFF or not visited.has(index)): bag.append(index)
			if bag.is_empty(): return current if repeat_mode != Repeat.OFF and not failed.has(current) else -1
		return bag[rng.randi_range(0, bag.size() - 1)]
	# Sequential order skips known-bad entries; bounded by one pass of the list.
	var index := current
	for step in count:
		index += 1
		if index >= count:
			if repeat_mode == Repeat.OFF: return -1
			index = 0
		if not failed.has(index): return index
	return -1

func _unvisited_failures() -> int:
	var total := 0
	for index in failed:
		if not visited.has(index): total += 1
	return total

## Record a decode failure so continuous playback never retries it in a loop.
func mark_failed(index: int):
	if index < 0 or index >= count: return
	if not failed.has(index): failed.append(index)
	bag.erase(index)

func previous_index() -> int:
	if shuffle and history.size() > 1: return history[history.size() - 2]
	if current > 0: return current - 1
	return count - 1 if repeat_mode != Repeat.OFF and count > 0 else current

func commit(index: int):
	if index < 0 or index >= count: return
	current = index
	failed.erase(index)
	if not visited.has(index): visited.append(index)
	bag.erase(index)
	if history.is_empty() or history.back() != index: history.append(index)
	# Keep a bounded navigation history even during hours of continuous playback.
	if history.size() > maxi(count * 2, 100): history.pop_front()

func commit_previous(index: int):
	if shuffle and history.size() > 1 and history[history.size() - 2] == index:
		history.pop_back()
		current = index
	else: commit(index)
