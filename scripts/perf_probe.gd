# Halfmoon perf probe — reports frame pacing to stderr and exits.
# HALFMOON_PERF=1 arms it. Reports mean/95th percentile frame time and the
# Engine draw-call counters, which is how we prove the backdrop split worked.
extends Node

var frames := 0
var acc := 0.0
var worst := 0.0
var samples: Array[float] = []


func _ready() -> void:
	if OS.get_environment("HALFMOON_PERF") == "":
		set_process(false)
		return
	print("PERF_PROBE on")


func _process(dt: float) -> void:
	frames += 1
	acc += dt
	samples.append(dt)
	if frames >= 240:
		_report()
		get_tree().quit()


func _report() -> void:
	var sorted := samples.duplicate()
	sorted.sort()
	var mean := acc / float(frames)
	var p50: float = sorted[int(frames * 0.50)]
	var p95: float = sorted[int(frames * 0.95)]
	var p99: float = sorted[mini(frames - 1, int(frames * 0.99))]
	print("PERF frames=%d mean=%.2fms p50=%.2fms p95=%.2fms p99=%.2fms" % [
		frames, mean * 1000.0, p50 * 1000.0, p95 * 1000.0, p99 * 1000.0
	])
	print("PERF draw_calls=%d objects=%d" % [
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.OBJECT_COUNT),
	])
