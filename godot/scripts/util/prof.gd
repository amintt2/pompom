class_name Prof
## Mesure du temps passe par fonction (--bench uniquement).
static var total := {}
static var peak := {}
static var count := {}


static func add(key: String, us: int) -> void:
	total[key] = int(total.get(key, 0)) + us
	peak[key] = maxi(int(peak.get(key, 0)), us)
	count[key] = int(count.get(key, 0)) + 1


static func reset() -> void:
	total.clear()
	peak.clear()
	count.clear()


static func report() -> void:
	var keys := total.keys()
	keys.sort_custom(func(a, b): return total[a] > total[b])
	for k in keys:
		print("PROF %-34s avg=%.3fms peak=%.2fms n=%d" % [k, float(total[k]) / count[k] / 1000.0, peak[k] / 1000.0, count[k]])
