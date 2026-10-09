extends SceneTree
## probe3 —— 「玩家掉出世界」定位器
##
## 只做一件事：把某一层地图**每一列的地板高度**打出来，找"井"。
## 判据：某列从 y=0 往下找第一个实心格，若它比相邻列深了 > 2 格，
## 就是一条竖井 —— 玩家掉进去就出不来（甚至掉出世界）。

const Cfg = preload("res://core/constants.gd")
const Layout = preload("res://gen/layout.gd")
const MK = preload("res://gen/motion_kernel.gd")

func _init() -> void:
	var seed64: int = int(Cfg.cmdline_value("--seed", "16838"))
	var floor_idx: int = int(Cfg.cmdline_value("--floor", "1"))
	var f = Layout.build_floor(Cfg.VERSION_KEY, seed64, floor_idx, false)
	var m = f.base
	print("层 %d seed=%d  w=%d h=%d  房=%d  spawn=%s goal=%s"
		% [floor_idx, seed64, m.w, m.h, f.rooms.size(), str(f.spawn), str(f.goal)])

	# 1) 每列的地板高度（第一个实心格）
	var prof: Array = []
	for x in range(m.w):
		var top: int = -1
		for y in range(m.h):
			if m.is_blocked(x, y):
				top = y
				break
		prof.append(top)

	# 2) 找井：比左右邻居都深 >= 3 格
	var wells: Array = []
	for x in range(2, m.w - 2):
		var t: int = int(prof[x])
		if t < 0:
			wells.append([x, -1])
			continue
		if t - int(prof[x - 2]) >= 3 and t - int(prof[x + 2]) >= 3:
			wells.append([x, t])
	print("竖井（比左右深 3 格以上）：%d 处 %s" % [wells.size(), str(wells.slice(0, 24))])

	# 3) 整列没有实心格 = 直接掉出世界
	var void_cols: Array = []
	for x in range(m.w):
		if int(prof[x]) < 0:
			void_cols.append(x)
	print("空列（整列无实心）：%d 处 %s" % [void_cols.size(), str(void_cols.slice(0, 24))])

	# 4) spawn 附近的地板剖面（掉出世界基本都发生在开局）
	var sx: int = f.spawn.x
	print("spawn 附近地板剖面 x=%d..%d：" % [maxi(0, sx - 4), mini(m.w - 1, sx + 60)])
	var line := ""
	for x in range(maxi(0, sx - 4), mini(m.w - 1, sx + 60)):
		line += "%d:%d " % [x, int(prof[x])]
	print(line)

	# 5) 房间边界：房间地板（x0 / x0+w-1 两列）与连接段地板是否一致
	for fr in f.rooms:
		var a: int = int(prof[fr.x0])
		var b: int = int(prof[fr.x0 + fr.w - 1])
		print("  房 %d %-8s x=%d..%d  地板 %d/%d  入口%s 出口%s"
			% [fr.index, fr.rtype, fr.x0, fr.x0 + fr.w - 1, a, b,
			   str(fr.entry_cell), str(fr.exit_cell)])

	# 6) 可达集大小 vs 地图总空格（可达集远小于空格说明有大片走不到/掉出去的地方）
	var R: Dictionary = m.reach_from(MK.get_kernel(), f.spawn, true)
	print("可达格数 = %d" % R.size())

	# 7) ASCII 剖面：x 段 × y 段（掉出世界的地方直接看）
	var xa: int = int(Cfg.cmdline_value("--x0", "300"))
	var xb: int = int(Cfg.cmdline_value("--x1", "400"))
	print("剖面 x=%d..%d：" % [xa, xb])
	var head := "     "
	for x in range(xa, mini(m.w, xb)):
		head += str(x % 10)
	print(head)
	for y in range(0, m.h):
		var line2 := "%3d |" % y
		for x in range(xa, mini(m.w, xb)):
			line2 += m.at(x, y)
		print(line2)
	quit(0)
