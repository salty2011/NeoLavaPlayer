extends SceneTree
const Queue = preload("res://playback_queue.gd")
func _initialize():
	var queue = Queue.new()
	assert(queue.next_index() == -1)
	queue.configure(4)
	assert(queue.next_index() == 0)
	queue.commit(0)
	assert(queue.next_index() == 1)
	queue.commit(3)
	assert(queue.next_index(true) == 0)
	queue.repeat_mode = Queue.Repeat.OFF
	assert(queue.next_index(true) == -1)
	queue.repeat_mode = Queue.Repeat.ONE
	assert(queue.next_index(true) == 3)
	assert(queue.next_index(false) == 0)
	queue.configure(4)
	queue.commit(0)
	queue.set_shuffle(true)
	queue.repeat_mode = Queue.Repeat.ALL
	queue.rng.seed = 12
	var seen: Array[int] = [0]
	for n in 3:
		var next = queue.next_index(true)
		assert(next != queue.current and not seen.has(next))
		# Candidate queries do not change the current track on decode failure.
		var current = queue.current
		queue.next_index(true)
		assert(queue.current == current)
		queue.commit(next)
		seen.append(next)
	assert(seen.size() == 4)
	for n in 100:
		var next = queue.next_index(true)
		assert(next != queue.current)
		queue.commit(next)
	var last = queue.current
	var previous = queue.previous_index()
	queue.commit_previous(previous)
	assert(queue.current == previous and queue.current != last)
	queue = Queue.new()
	queue.configure(4)
	queue.set_shuffle(true)
	queue.repeat_mode = Queue.Repeat.OFF
	queue.commit(0)
	seen = [0]
	for n in 3:
		var next = queue.next_index(true)
		assert(next >= 0 and not seen.has(next))
		queue.commit(next)
		seen.append(next)
	assert(queue.next_index(true) == -1)
	queue = Queue.new()
	queue.configure(1)
	queue.commit(0)
	queue.set_shuffle(true)
	assert(queue.next_index(true) == 0)
	queue.repeat_mode = Queue.Repeat.OFF
	assert(queue.next_index(true) == -1)
	# Failed decodes are excluded from shuffle bags and sequential order.
	queue = Queue.new()
	queue.configure(4)
	queue.commit(0)
	queue.set_shuffle(true)
	queue.rng.seed = 3
	var bad = queue.next_index(true)
	queue.mark_failed(bad)
	assert(not queue.bag.has(bad))
	for n in 50:
		var next = queue.next_index(true)
		assert(next != bad and next != queue.current)
		queue.commit(next)
	queue = Queue.new()
	queue.configure(4)
	queue.commit(0)
	queue.mark_failed(1)
	queue.mark_failed(2)
	assert(queue.next_index(true) == 3)
	queue.commit(3)
	assert(queue.next_index(true) == 0)
	queue.repeat_mode = Queue.Repeat.OFF
	assert(queue.next_index(true) == -1)
	# All-bad playlist terminates instead of looping.
	queue = Queue.new()
	queue.configure(3)
	queue.commit(0)
	queue.mark_failed(1)
	queue.mark_failed(2)
	queue.mark_failed(0)
	assert(queue.next_index(true) == -1)
	queue.set_shuffle(true)
	assert(queue.next_index(true) == -1)
	# A later successful load clears the failure mark.
	queue.commit(2)
	assert(not queue.failed.has(2))
	queue = Queue.new()
	queue.configure(3)
	queue.set_shuffle(true)
	queue.repeat_mode = Queue.Repeat.OFF
	queue.commit(0)
	queue.mark_failed(1)
	assert(queue.next_index(true) == 2)
	queue.commit(2)
	assert(queue.next_index(true) == -1)
	print("PASS: queue empty, sequential, repeat off/all/one, manual next, shuffled exhaustion, no immediate repeats, failed decode candidates, previous history, single-track queue, failed-decode exclusion (shuffle, sequential, all-bad termination)")
	quit()
