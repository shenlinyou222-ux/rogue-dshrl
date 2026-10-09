extends SceneTree
## probe12 —— 机器人卡死点到底是不是"进得去出不来"的陷阱格？
##
## 用法：--seed=26757 --floor=1 --cx=217 --cy=7
## 输出：该格的字符、是否站立格、在不在 宽松F / 严格F / 严格B 里、附近地形切片。

const Cfg = preload("res://core/constants.gd")
const Layout = preload("res://gen/layout.gd")
const MK = preload("res://gen/motion_kernel.gd")
const VM = preload("res://gen/voxel_map.gd")

func _init() -> void:
	var seed64: int = int(Cfg.cmdline_value("--seed", "26757"))
	var fi: int = int(Cfg.cmdline_value("--floor", "1"))
	var cx: int = int(Cfg.cmdline_value("--cx", "217"))
	var cy: int = int(Cfg.cmdline_value("--cy", "7"))
	var f = Layout.build_floor(Cfg.VERSION_KEY, seed64, fi, false)
	var m = f.base
	var doors: Array = []
	for y in range(m.h):
		var row: String = m.cells[y]
		for x in range(m.w):
			if row[x] == VM.DOOR:
				doors.append(Vector2i(x, y))
	var om = m
	if not doors.is_empty():
		om = m.open_cells(doors)
	var kernel = MK.get_kernel()
	var c := Vector2i(cx, cy)
	print("seed=%d 层=%d spawn=%s goal=%s 钥匙=%s 开关=%s 陷阱填=%d 开格=%d"
		% [seed64, fi, str(f.spawn), str(f.goal), str(f.key_cell), str(f.switch_cell),
			f.trap_filled, doors.size()])
	print("目标格 %s 字符=%s 站立=%s" % [str(c), om.at(cx, cy), str(om.standable(cx, cy))])
	var fl: Dictionary = om.reach_from(kernel, f.spawn, false, false)
	print("  宽松F 算完 %d" % fl.size())
	var fh: Dictionary = om.reach_from(kernel, f.spawn, false, true)
	print("  严格F 算完 %d" % fh.size())
	var bh: Dictionary = om.reach_back_from(kernel, f.goal, true)
	print("  严格B 算完 %d" % bh.size())
	var bl: Dictionary = bh
	print("宽松F=%d 严格F=%d | 严格B=%d 宽松B=%d" % [fl.size(), fh.size(), bh.size(), bl.size()])
	print("  在宽松F=%s 在严格F=%s 在严格B=%s 在宽松B=%s"
		% [str(fl.has(c)), str(fh.has(c)), str(bh.has(c)), str(bl.has(c))])
	print("  是陷阱（宽松F\\严格B）=%s" % str(fl.has(c) and not bh.has(c)))
	print("  spawn 在严格F=%s；goal 在严格F=%s；spawn 在严格B=%s；goal 在严格B=%s"
		% [str(fh.has(f.spawn)), str(fh.has(f.goal)), str(bh.has(f.spawn)), str(bh.has(f.goal))])
	# 地形切片
	print("地形切片（列 %d..%d，行 %d..%d；每格一个字符，S=spawn G=goal K=钥匙 B=开关 D=门）"
		% [cx - 8, cx + 12, cy - 4, cy + 6])
	var marks := {f.spawn: "S", f.goal: "G"}
	if f.key_cell.x >= 0:
		marks[f.key_cell] = "K"
	if f.switch_cell.x >= 0:
		marks[f.switch_cell] = "B"
	for y in range(cy - 4, cy + 7):
		var line := "y=%2d " % y
		for x in range(cx - 8, cx + 13):
			if Vector2i(x, y) == c:
				line += "@"
			elif marks.has(Vector2i(x, y)):
				line += str(marks[Vector2i(x, y)])
			else:
				line += om.at(x, y)
		print(line)
	quit()
