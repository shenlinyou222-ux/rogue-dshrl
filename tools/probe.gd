extends SceneTree

const JP = preload("res://core/jump_phys.gd")
const MK = preload("res://gen/motion_kernel.gd")
const GM = preload("res://gen/gridmap.gd")
const VM = preload("res://gen/voxel_map.gd")

func _p(s: String) -> void:
	print(s)
	printerr("PROBE " + s)

func _init() -> void:
	var t0 := Time.get_ticks_msec()
	_p("start")
	var kernel = MK.get_kernel()
	_p("kernel compiled: %s" % kernel.stats())
	_p("gap cap: %s" % kernel.gap_capacity_text())

	t0 = Time.get_ticks_msec()
	var spec = GM.GenSpec.new()
	spec.w = 96
	spec.h = 34
	spec.seed64 = 12345
	_p("calling generate w=%d h=%d" % [spec.w, spec.h])
	var res: Dictionary = GM.generate(spec)
	_p("generate done in %d ms" % (Time.get_ticks_msec() - t0))
	var m = res["map"]
	var rep = res["report"]
	_p("map %dx%d spawn=%s goal=%s nodes=%d errors=%s repairs=%d"
		% [m.w, m.h, str(m.spawn), str(m.goal), m.nodes().size(),
		   str(rep.errors), rep.repairs.size()])

	t0 = Time.get_ticks_msec()
	var reach: Dictionary = m.reach_from(kernel, m.spawn, true)
	_p("reach_from fwd: %d nodes in %d ms, goal reached=%s"
		% [reach.size(), Time.get_ticks_msec() - t0, str(reach.has(m.goal))])

	t0 = Time.get_ticks_msec()
	var world = GM.place_mechanisms(m, spec, rep)
	_p("place_mechanisms in %d ms" % (Time.get_ticks_msec() - t0))

	t0 = Time.get_ticks_msec()
	var sol = world.solve()
	_p("solve in %d ms ok=%s rounds=%d trace=%s"
		% [Time.get_ticks_msec() - t0, str(sol["ok"]), sol["rounds"], str(sol["trace"])])

	t0 = Time.get_ticks_msec()
	var crit: Array = world.critical()
	_p("critical in %d ms -> %s" % [Time.get_ticks_msec() - t0, str(crit)])

	quit(0)
