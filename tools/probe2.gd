extends SceneTree

const MK = preload("res://gen/motion_kernel.gd")
const GM = preload("res://gen/gridmap.gd")
const VM = preload("res://gen/voxel_map.gd")

func _init() -> void:
	var kernel = MK.get_kernel()
	for si in range(16):
		var spec = GM.GenSpec.new()
		spec.w = 96
		spec.h = 34
		spec.seed64 = 5150 + si * 31337
		var gen: Dictionary = GM.generate(spec)
		var m = gen["map"]
		var rep = gen["report"]
		var world = GM.place_mechanisms(m, spec, rep)
		var sol = world.solve()
		if sol["ok"]:
			continue
		print("--- FAIL seed=%d goal=%s spawn=%s" % [spec.seed64, str(m.goal), str(m.spawn)])
		print("    trace=%s" % str(sol["trace"]))
		print("    taken=%s opened=%s" % [str(sol["taken"]), str(sol["opened"])])
		print("    items=%s" % str(world.items))
		for mech in world.mechanisms:
			print("    mech %s kind=%s cells=%d need_region=%s key=%s"
				% [mech.mid, mech.kind, mech.pass_cells.size(),
				   str(mech.need_region), str(mech.key_item)])
			var first: Vector2i = mech.pass_cells[0] if mech.pass_cells.size() > 0 else Vector2i(-1, -1)
			print("      first cell=%s standable_on_base=%s" % [str(first), str(world.base.standable(first.x, first.y))])
		var keycell: Vector2i = world.items["key"]
		print("    key cell=%s standable=%s blocked=%s cell_char=%s"
			% [str(keycell), str(world.base.standable(keycell.x, keycell.y)),
			   str(world.base.is_blocked(keycell.x, keycell.y)),
			   world.base.at(keycell.x, keycell.y)])
		# 出生点到该格的可达
		var reach: Dictionary = world.base.reach_from(kernel, world.base.spawn, true)
		var near := false
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				if reach.has(Vector2i(keycell.x + dx, keycell.y + dy)):
					near = true
		print("    key in reach=%s near=%s reach_size=%d goal_in_reach=%s"
			% [str(reach.has(keycell)), str(near), reach.size(), str(reach.has(m.goal))])
		var xmin := 9999
		var xmax := -9999
		for p in reach.keys():
			xmin = mini(xmin, p.x)
			xmax = maxi(xmax, p.x)
		print("    reach x range = [%d, %d]" % [xmin, xmax])
		var rows := []
		for yy in range(0, m.h):
			var row := ""
			for xx in range(24, 40):
				row += m.at(xx, yy)
			rows.append("      y=%2d |%s|" % [yy, row])
		print("    map x=24..39（真实矩阵）:")
		for r in rows:
			print(r)
		print("    rep.height[24..39] = %s" % str(rep.height.slice(24, 40)))
		quit(0)
