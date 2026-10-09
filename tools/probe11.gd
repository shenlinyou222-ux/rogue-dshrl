extends SceneTree
## probe11 —— 「严格掩码到底在拒绝哪一种走法」定位器
##
## probe10 的结论很刺眼：严格掩码（= 运行时的"任何实心格都挡人"）下，
## 连终点都不在出生点的可达集合里；而宽松掩码（= 运动核自己的"上下都实心才算墙"）
## 下一切正常。两者必有一个在骗人。
##
## 本探测器：用宽松掩码做 BFS（掩码预先算好，别在循环里反复算），
## 然后沿**出生点→终点的那条路**逐步用严格掩码复核，
## 把被拒的走法连同**挡住它的格子**打出来。

const Cfg = preload("res://core/constants.gd")
const Layout = preload("res://gen/layout.gd")
const MK = preload("res://gen/motion_kernel.gd")
const VM = preload("res://gen/voxel_map.gd")

func _init() -> void:
	var seed64: int = int(Cfg.cmdline_value("--seed", "3000"))
	var fi: int = int(Cfg.cmdline_value("--floor", "1"))
	var f = Layout.build_floor(Cfg.VERSION_KEY, seed64, fi, false)
	var m = f.base
	var doors: Array = []
	for y in range(m.h):
		var row: String = m.cells[y]
		for x in range(m.w):
			if row[x] == VM.DOOR:
				doors.append(Vector2i(x, y))
	if not doors.is_empty():
		m = m.open_cells(doors)
	var kernel = MK.get_kernel()
	var spawn: Vector2i = f.spawn
	print("seed=%d 层=%d w=%d spawn=%s goal=%s 门%d 开"
		% [seed64, fi, m.w, str(spawn), str(f.goal), doors.size()])

	var offs: Array = kernel.cells
	var masks: Array = []
	for i in range(offs.size()):
		masks.append(kernel.mask_of(offs[i]))

	# --- 1) 宽松掩码 BFS，记录进入步长 ---
	var entry := {spawn: 0}
	var order: Array = [spawn]
	var head := 0
	while head < order.size():
		var p: Vector2i = order[head]
		head += 1
		for i in range(offs.size()):
			var o: Vector2i = offs[i]
			var q := Vector2i(p.x + o.x, p.y + o.y)
			if entry.has(q) or not m.standable(q.x, q.y):
				continue
			if not _ok(m, p, masks[i], false):
				continue
			entry[q] = i
			order.append(q)
	print("宽松可达 %d 格；终点在内=%s；钥匙在内=%s；开关在内=%s"
		% [order.size(), str(entry.has(f.goal)), str(entry.has(f.key_cell)), str(entry.has(f.switch_cell))])

	# --- 2) 沿 出生点→终点 的路逐步严格复核 ---
	if not entry.has(f.goal):
		print("终点在宽松图里都不可达，先别查严格掩码。")
		quit()
		return
	var chain: Array = []
	var cur: Vector2i = f.goal
	var guard := 0
	while cur != spawn and guard < 20000:
		guard += 1
		var i2: int = int(entry[cur])
		chain.append([Vector2i(cur.x - offs[i2].x, cur.y - offs[i2].y), i2, cur])
		cur = Vector2i(cur.x - offs[i2].x, cur.y - offs[i2].y)
	chain.reverse()
	print("出生点→终点 共 %d 步" % chain.size())
	var bad := 0
	var kinds := {}
	for step in chain:
		var p: Vector2i = step[0]
		var i3: int = int(step[1])
		var q: Vector2i = step[2]
		if _ok(m, p, masks[i3], true):
			continue
		bad += 1
		var blockers: Array = []
		for rel in masks[i3]:
			var r: Vector2i = rel
			if m.blocked_at(p.x + r.x, p.y + r.y):
				blockers.append("%s%s" % [str(Vector2i(p.x + r.x, p.y + r.y)), m.at(p.x + r.x, p.y + r.y)])
		var relc := Vector2i(999, 999)
		if not blockers.is_empty():
			relc = Vector2i(int(str(blockers[0]).split("(")[1].split(",")[0]) - p.x,
				int(str(blockers[0]).split(",")[1].split(")")[0]) - p.y)
		var kk: String = "步长%s 首挡@%s" % [str(offs[i3]), str(relc)]
		kinds[kk] = int(kinds.get(kk, 0)) + 1
		if bad <= 5:
			print("  ✗ %s → %s 步长%s 挡=%s 起点周围=%s"
				% [str(p), str(q), str(offs[i3]), str(blockers.slice(0, 3)), _around(m, p)])
	print("--- 这条路 %d 步里有 %d 步在严格掩码下非法 ---" % [chain.size(), bad])
	var keys: Array = kinds.keys()
	keys.sort_custom(func(a, b): return int(kinds[a]) > int(kinds[b]))
	for i in range(mini(8, keys.size())):
		print("    %4d 次  %s" % [int(kinds[keys[i]]), str(keys[i])])
	quit()

func _ok(m, p: Vector2i, mask: Array, strict: bool) -> bool:
	for rel in mask:
		var r: Vector2i = rel
		if strict:
			if m.blocked_at(p.x + r.x, p.y + r.y):
				return false
		elif m.is_wall(p.x + r.x, p.y + r.y):
			return false
	return true

func _around(m, c: Vector2i) -> String:
	var out := ""
	for dy in range(-2, 2):
		for dx in range(-1, 2):
			out += m.at(c.x + dx, c.y + dy)
		out += "/"
	return out
