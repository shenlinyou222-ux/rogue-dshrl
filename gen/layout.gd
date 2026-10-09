# Layout —— 关卡布局（3 层 × 11 房 = 33 房）
#
# 做法：**链式插入 + 回溯**（ManiaMap 的思路，原型移植，不用它的 RNG 流）。
#   1. 先定「房间序列」——配额是构造式约束：start 1 个、exit/boss 1 个、
#      rest 1 个（层末）、shop <= 1、secret <= 1、elite <= 2，其余 normal；
#   2. 再定「行剖面」——每个房间的入口行/出口行，房间内 |Δrow| <= 3，
#      房间之间**出口行 == 下一房入口行**（跨房间只需走平地，地图方案 §4.4）；
#   3. 再拼「全局矩阵」——房间按 x 顺序贴进一张大矩阵，中间用 6 列连接段补平；
#   4. 最后布机关——门只能放在**连接段**（连接段里没有上层平台，封一列就是真封）；
#
# 为什么门必须放连接段：房间内部有上层长廊，若在房间里封列，玩家还能从上层
# 绕过去（原型里实测过：门变成完全冗余）。连接段是纯粹的走廊，封死了就是封死了。
#
# 为什么门必须**成链**（钥匙在前、开关在中间）：一维链上任何「背面开关」若把
# 唯一通路封在触发点之前，就是死锁。链式顺序保证每个门的前置条件都在它之前。

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const VM = preload("res://gen/voxel_map.gd")
const MK = preload("res://gen/motion_kernel.gd")
const GM = preload("res://gen/gridmap.gd")
const Room = preload("res://gen/room.gd")
const Rng = preload("res://core/rng.gd")
const Dig = preload("res://core/digest.gd")

const GAP_COLS := 6                # 房间之间的连接段列数（>= 门段 96px 的一半即可）
const ROW_BAND := [20, 22, 24, 26, 28]   # 走廊地面行候选（房间 h=34，上方要留出长廊空间）

# --------------------------------------------------------------------------

class FloorRoom:
	var index: int = 0
	var rid: String = ""
	var rtype: String = "normal"
	var x0: int = 0            # 全局列偏移
	var w: int = 0
	var h: int = 0
	var variant = null         # Room.RoomVariant
	var slots: Array = []      # 全局坐标内容槽
	var entry_cell: Vector2i = Vector2i.ZERO
	var exit_cell: Vector2i = Vector2i.ZERO

class Link:
	var from_index: int = 0
	var to_index: int = 0
	var x0: int = 0            # 连接段起始列
	var x1: int = 0            # 连接段结束列
	var row: int = 0
	var kind: String = "walk"

class Floor:
	var floor_index: int = 1
	var version_key: String = ""
	var seed64: int = 0
	var map = null                     # 全局 VoxelMap（含机关已开的最终态由 solve 决定）
	var base = null                    # 机关全关的 base 矩阵
	var rooms: Array = []
	var links: Array = []
	var world = null                   # GM.World（机关 + 不动点求解）
	var spawn: Vector2i = Vector2i.ZERO
	var goal: Vector2i = Vector2i.ZERO
	var key_cell: Vector2i = Vector2i(-1, -1)
	var switch_cell: Vector2i = Vector2i(-1, -1)
	var mechanism_doors: Array = []    # [ {x, y, mid} ]
	var mechanism_world_list: Array = []
	var mechanism_items: Dictionary = {}
	var errors: Array = []
	var trap_filled: int = 0        # 陷阱剪除填掉的格子数（诊断用）
	var gen_ms: int = 0

	func room_at_x(x: int) -> int:
		for r in rooms:
			if x >= r.x0 and x < r.x0 + r.w:
				return r.index
		return -1

	func width() -> int:
		return map.w if map != null else 0

	func height() -> int:
		return map.h if map != null else 0

# --------------------------------------------------------------------------
# 房间序列（配额 = 构造式约束）
# --------------------------------------------------------------------------

static func plan_types(floor_index: int, n: int, rnd) -> Array:
	var is_boss: bool = floor_index in Cfg.RUN["boss_floors"]
	var types: Array = []
	types.append("start")
	var mid := n - 2
	var pool: Array = []
	if is_boss:
		# Boss 层：末尾是 boss 房，elite 减 1（别让玩家在 Boss 前被掏空）
		pool.append("rest")
		for i in range(int(Cfg.ROOM_QUOTA["elite"]) - 1):
			pool.append("elite")
	else:
		pool.append("rest")
		for i in range(int(Cfg.ROOM_QUOTA["elite"])):
			pool.append("elite")
		if rnd.chance(50):
			pool.append("secret")
	if rnd.chance(70):
		pool.append("shop")
	pool.append("treasure")
	while pool.size() < mid:
		pool.append("normal")
	pool = pool.slice(0, mid)
	pool = rnd.shuffle(pool)
	# 构造式约束：rest 必须在层末（Boss 前给一次喘息），且非 start 的第一间不能是 elite
	var ordered: Array = []
	var rest_at: int = mid - 1
	for i in range(mid):
		if i == rest_at:
			ordered.append("rest")
		else:
			var t: String = str(pool[i])
			if t == "rest":
				t = "normal"
			if i == 0 and (t == "elite" or t == "treasure"):
				t = "normal"
			ordered.append(t)
	for t2 in ordered:
		types.append(t2)
	types.append("boss" if is_boss else "exit")
	return types

# --------------------------------------------------------------------------
# 行剖面
# --------------------------------------------------------------------------

static func plan_rows(types: Array, rnd) -> Array:
	# 返回 [entry_row, exit_row] 列表，保证相邻房间接口行一致
	var rows: Array = []
	var cur: int = ROW_BAND[1 + rnd.range_i(ROW_BAND.size() - 2)]
	for i in range(types.size()):
		var entry: int = cur
		var delta: int = 0
		if str(types[i]) == "start" or i == types.size() - 1:
			delta = 0
		else:
			delta = rnd.range_lo_hi(-3, 3)
		var exit_r: int = clampi(entry + delta, ROW_BAND[0], ROW_BAND[ROW_BAND.size() - 1])
		rows.append([entry, exit_r])
		cur = exit_r
	return rows

# --------------------------------------------------------------------------
# 主入口
# --------------------------------------------------------------------------

static func build_floor(version_key: String, seed64: int, floor_index: int,
						deep_verify: bool = true) -> Object:
	var t0 := Time.get_ticks_msec()
	var kernel = MK.get_kernel()
	var f := Floor.new()
	f.floor_index = floor_index
	f.version_key = version_key
	f.seed64 = seed64

	var rnd = Rng.stream(version_key, seed64, floor_index, "layout", "v1")
	var n: int = int(Cfg.RUN["rooms_per_floor"])
	var types: Array = plan_types(floor_index, n, rnd)
	var rows: Array = plan_rows(types, rnd)

	# ---- 1) 逐房生成 ----
	var variants: Array = []
	for i in range(n):
		var rtype: String = str(types[i])
		var spec = Room.RoomSpec.new()
		spec.rid = "f%d_r%02d" % [floor_index, i]
		spec.rtype = rtype
		spec.version_key = version_key
		spec.seed64 = seed64 ^ Dig.h32("room|%d|%d" % [floor_index, i])
		spec.entry_row = int(rows[i][0])
		spec.exit_row = int(rows[i][1])
		spec.w = 48 + rnd.range_i(4) * 6
		spec.h = 34
		spec.with_gallery = rtype != "boss" and rtype != "start"
		spec.platform_budget = 1 + rnd.range_i(3)
		spec.spike_chance = 8 + rnd.range_i(10) + floor_index * 2
		# 战斗房多平台，休息/商店房少一点（少一点跳跃惩罚）
		if rtype == "rest" or rtype == "shop":
			spec.platform_budget = 1
			spec.spike_chance = 4
		var v = Room.build(spec)
		if not v.errors.is_empty():
			f.errors.append("房 %s: %s" % [spec.rid, str(v.errors)])
		variants.append(v)

	# ---- 2) 全局矩阵拼接 ----
	var total_w := 0
	for i in range(n):
		total_w += int(variants[i].w)
	total_w += GAP_COLS * (n - 1)
	var gh: int = 34
	var grid: Array = []
	for y in range(gh):
		var row := PackedStringArray()
		row.resize(total_w)
		for x in range(total_w):
			row[x] = VM.SOLID
		grid.append(row)

	var curs: int = 0
	for i in range(n):
		var v = variants[i]
		var fr = FloorRoom.new()
		fr.index = i
		fr.rid = v.rid
		fr.rtype = v.rtype
		fr.x0 = curs
		fr.w = v.w
		fr.h = v.h
		fr.variant = v
		# 贴图（房间矩阵 h=34 与全局一致）
		for y in range(v.h):
			for x in range(v.w):
				grid[y][curs + x] = v.map.at(x, y)
		fr.entry_cell = Vector2i(curs + v.entry.x, v.entry.y)
		fr.exit_cell = Vector2i(curs + v.exit_cell.x, v.exit_cell.y)
		for s in v.slots:
			fr.slots.append(Vector2i(curs + s.x, s.y))
		f.rooms.append(fr)
		curs += v.w
		if i < n - 1:
			var lk = Link.new()
			lk.from_index = i
			lk.to_index = i + 1
			lk.x0 = curs
			lk.x1 = curs + GAP_COLS - 1
			lk.row = int(rows[i][1])
			var lk_row: int = lk.row
			for x in range(lk.x0, lk.x1 + 1):
				grid[0][x] = VM.SOLID
				for y in range(1, lk_row):
					grid[y][x] = VM.EMPTY
				for y in range(lk_row, gh):
					grid[y][x] = VM.SOLID
			f.links.append(lk)
			curs += GAP_COLS

	var base_map = VM.from_strings(grid)
	f.spawn = f.rooms[0].entry_cell
	f.goal = f.rooms[n - 1].exit_cell
	base_map.spawn = f.spawn
	base_map.goal = f.goal

	# ---- 3) 布机关（只在连接段） ----
	_place_gates(f, grid, base_map, rows, rnd)

	# ---- 3.5) 陷阱剪除：把"进得去出不来"的地形填掉 ----
	# 必须在机关布好之后（门列算地形的一部分），且在验证之前。
	var prune_map = VM.from_strings(grid)
	prune_map.spawn = f.spawn
	prune_map.goal = f.goal
	var prot: Array = [f.spawn, f.goal]
	if f.key_cell.x >= 0:
		prot.append(f.key_cell)
	if f.switch_cell.x >= 0:
		prot.append(f.switch_cell)
	for mm in f.mechanism_world_list:
		for pc in mm.pass_cells:
			prot.append(pc)
		if mm.need_region != null:
			prot.append(mm.need_region)
	f.trap_filled = GM.prune_traps(prune_map, kernel, prot, null)
	for y in range(prune_map.h):
		var prow: String = prune_map.cells[y]
		for x in range(prune_map.w):
			grid[y][x] = prow[x]

	var final_map = VM.from_strings(grid)
	final_map.spawn = f.spawn
	final_map.goal = f.goal
	f.base = final_map
	f.world = GM.World.new(final_map, kernel)
	f.world.mechanisms = f.mechanism_world_list
	f.world.items = f.mechanism_items
	f.world.targets = [f.goal]
	f.map = final_map
	f.gen_ms = Time.get_ticks_msec() - t0
	# deep_verify 会额外跑 critical()（4 次 BFS 闭包，约占每层 40% 的生成时间）。
	# 自检里必须开；运行时关掉 —— 因为「门都是关键机关」是**构造性**结论
	# （门列被封 + 前置条件都在门之前），不是概率性质，不需要每局重证。
	f.errors.append_array(verify_floor(f, kernel, types, deep_verify))
	return f

# --------------------------------------------------------------------------
# 楼层级断言（与房间级 R1..R5 一起构成本层的全部硬约束）
# --------------------------------------------------------------------------

static func verify_floor(f, kernel, types, deep_verify: bool = true) -> Array:
	var errs: Array = []
	var sol = f.world.solve()
	if not sol["ok"]:
		errs.append("G1 求解后出口不可达（unreachable=%s trace=%s）"
			% [str(sol["unreachable"]), str(sol["trace"])])

	# G2 基础地图（机关全关 + 不捡道具）出口必须不可达 —— 门真的在把关
	var closed = f.world.solve(true, [], false)
	if closed["ok"]:
		errs.append("G2 不捡道具也能到出口（门没在把关）")

	# G3 门全部是关键机关（昂贵：4 次闭包；运行时靠构造性保证，不重跑）
	if deep_verify:
		var crit: Array = f.world.critical()
		if crit.size() != f.world.mechanisms.size():
			errs.append("G3 关键机关 %d/%d（多出来的是冗余）：%s"
				% [crit.size(), f.world.mechanisms.size(), str(crit)])

	# G4 钥匙必须在「未开门」状态下可达（无死锁）
	var r_closed: Dictionary = f.base.reach_from(kernel, f.spawn, true)
	if not r_closed.has(f.key_cell) and not _near_cell(r_closed, f.key_cell, 2):
		errs.append("G4 钥匙 %s 在未开门状态下不可达（死锁）" % str(f.key_cell))

	# G5 单调性：R_关 ⊆ R_开
	var r_open: Dictionary = sol["reach"]
	for p in r_closed.keys():
		if not r_open.has(p):
			errs.append("G5 单调性被破坏：%s 在开拓后反而不可达" % str(p))
			break

	# G6 最终矩阵每一列都必须有地面（不许出现通天井）
	for x in range(f.map.w):
		var has_floor := false
		for y in range(f.map.h):
			if f.map.is_blocked(x, y):
				has_floor = true
				break
		if not has_floor:
			errs.append("G6 列 %d 完全没有实心格" % x)
			break

	# G7 配额（构造式约束）
	var counts := {}
	for t in types:
		counts[t] = int(counts.get(t, 0)) + 1
	if int(counts.get("start", 0)) != 1:
		errs.append("G7 start 房必须恰好 1 个")
	if int(counts.get("boss", 0)) + int(counts.get("exit", 0)) != 1:
		errs.append("G7 boss/exit 房必须恰好 1 个")
	if int(counts.get("rest", 0)) != 1:
		errs.append("G7 rest 房必须恰好 1 个")
	if int(counts.get("shop", 0)) > int(Cfg.ROOM_QUOTA["shop"]):
		errs.append("G7 shop 超配额")
	if int(counts.get("elite", 0)) > int(Cfg.ROOM_QUOTA["elite"]):
		errs.append("G7 elite 超配额")
	if int(counts.get("secret", 0)) > int(Cfg.ROOM_QUOTA["secret"]):
		errs.append("G7 secret 超配额")
	# Boss 层规则
	var is_boss: bool = f.floor_index in Cfg.RUN["boss_floors"]
	if is_boss and int(counts.get("boss", 0)) != 1:
		errs.append("G7 Boss 层没有 Boss 房")
	if not is_boss and int(counts.get("boss", 0)) != 0:
		errs.append("G7 非 Boss 层出现 Boss 房")

	# G8 房间接口行一致（跨房间只需走平地）
	for i in range(f.rooms.size() - 1):
		var a = f.rooms[i]
		var b = f.rooms[i + 1]
		if absi(a.exit_cell.y - b.entry_cell.y) != 0:
			errs.append("G8 房 %d→%d 接口行不一致（%d vs %d）"
				% [i, i + 1, a.exit_cell.y, b.entry_cell.y])

	# G9 房间数
	if f.rooms.size() != int(Cfg.RUN["rooms_per_floor"]):
		errs.append("G9 房间数 %d != %d" % [f.rooms.size(), Cfg.RUN["rooms_per_floor"]])
	return errs

static func _near_cell(reach: Dictionary, cell: Vector2i, r: int) -> bool:
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			if reach.has(Vector2i(cell.x + dx, cell.y + dy)):
				return true
	return false

# --------------------------------------------------------------------------
# 机关：钥匙门 → 背面开关门（都放在连接段）
# --------------------------------------------------------------------------

static func _place_gates(f, grid: Array, base_map, rows: Array, rnd) -> void:
	var n: int = f.rooms.size()
	var links: Array = f.links
	var mechanisms: Array = []
	var items: Dictionary = {}

	# 门 1：第 55% 处的连接段；门 2：第 85% 处的连接段
	var l1: int = clampi(int(links.size() * 0.55), 0, links.size() - 1)
	var l2: int = clampi(int(links.size() * 0.85), 0, links.size() - 1)
	if l2 <= l1:
		l2 = links.size() - 1
	if l1 == l2:
		l2 = -1

	# 门 1（钥匙门）—— 封连接段中间一列
	var link1: Link = links[l1]
	var d1x: int = link1.x0 + GAP_COLS / 2
	var d1row: int = link1.row
	var d1_cells: Array = []
	for y in range(1, d1row):
		grid[y][d1x] = VM.SOLID
	for k in range(6):
		var yy: int = d1row - 1 - k
		if yy >= 1:
			grid[yy][d1x] = VM.DOOR
			d1_cells.append(Vector2i(d1x, yy))
	var door1 = GM.Mechanism.new("gate_key_f%d" % f.floor_index, "door")
	door1.pass_cells = d1_cells
	door1.key_item = "key_f%d" % f.floor_index
	door1.desc = "钥匙门 @列 %d（第 %d/%d 房之间）" % [d1x, link1.from_index + 1, n]
	mechanisms.append(door1)

	# 钥匙：放在门 1 之前的某间房（靠右的房，逼玩家至少走一段）
	# ⚠️ **必须放在主走廊上**（不能放在上层长廊）：
	#    机器人实测「钥匙在高处」时 4/8 局卡死在门前 —— 因为「不探索的玩家」
	#    会直接走过上层平台底下，永远拿不到钥匙。这是设计约束，不是机器人笨。
	var key_room: int = clampi(link1.from_index - rnd.range_i(2) - 1, 1, maxi(1, link1.from_index))
	var kr = f.rooms[key_room]
	var key_slot: Vector2i = _pick_main_path_slot(kr, rnd)
	grid[key_slot.y][key_slot.x] = VM.KEY
	items[door1.key_item] = key_slot
	f.key_cell = key_slot

	# 门 2（背面开关门）—— 开关在门 1 与门 2 之间
	if l2 >= 0 and l2 > l1:
		var link2: Link = links[l2]
		var d2x: int = link2.x0 + GAP_COLS / 2
		var d2row: int = link2.row
		var d2_cells: Array = []
		for y in range(1, d2row):
			grid[y][d2x] = VM.SOLID
		for k2 in range(6):
			var yy2: int = d2row - 1 - k2
			if yy2 >= 1:
				grid[yy2][d2x] = VM.DOOR
				d2_cells.append(Vector2i(d2x, yy2))
		var sw_room: int = clampi(link2.from_index, link1.to_index, link2.from_index)
		var sr = f.rooms[sw_room]
		var sw_slot: Vector2i = _pick_main_path_slot(sr, rnd)
		grid[sw_slot.y][sw_slot.x] = VM.SWITCH
		var door2 = GM.Mechanism.new("gate_switch_f%d" % f.floor_index, "gate")
		door2.pass_cells = d2_cells
		door2.need_region = sw_slot
		door2.desc = "背面开关门 @列 %d（开关在房 %d，需先过钥匙门）" % [d2x, sw_room]
		mechanisms.append(door2)
		f.switch_cell = sw_slot

	f.mechanism_world_list = mechanisms
	f.mechanism_items = items
	for m in mechanisms:
		for c in m.pass_cells:
			f.mechanism_doors.append({"x": c.x, "y": c.y, "mid": m.mid})

# --------------------------------------------------------------------------
# 内容槽挑选
# --------------------------------------------------------------------------

## pick_high=true 时优先挑高处（上层长廊），保证钥匙/开关不总在平地上。
## 进度道具专用：**主走廊上的槽** —— 取 y 最大（最低）的几个槽里随机一个。
##
## 为什么不能用 _pick_slot(.., false)：房间里有"上层长廊"（3 格高的平台群），
## 长廊上的内容槽数量往往过半，avg_y 会被拉高，于是"低槽"里也会混进高处的槽。
## 实测：钥匙被放到 y=10（地面在 y=23），机器人 100% 卡死在门前 ——
## **不探索的玩家 = 只走地面的玩家**，进度道具放在地面上是硬约束，不是偏好。
static func _pick_main_path_slot(fr, rnd) -> Vector2i:
	var slots: Array = fr.slots
	if slots.is_empty():
		return fr.entry_cell
	var sorted: Array = slots.duplicate()
	sorted.sort_custom(func(a, b): return a.y > b.y)
	var n: int = mini(3, sorted.size())
	return sorted[rnd.range_i(n)]

## 注意：fr.slots 里存的**已经是全局坐标**（build_floor 贴图时加过 x0 了），
## 这里绝不能再加一次 —— 加两次会直接把道具写到地图外面去（实测索引越界）。
static func _pick_slot(fr, rnd, pick_high: bool) -> Vector2i:
	var slots: Array = fr.slots
	if slots.is_empty():
		return fr.entry_cell
	var hi: Array = []
	var lo: Array = []
	var avg_y := 0
	for s in slots:
		avg_y += s.y
	avg_y = int(avg_y / slots.size())
	for s in slots:
		if s.y < avg_y - 2:
			hi.append(s)
		else:
			lo.append(s)
	var pool: Array = hi if (pick_high and not hi.is_empty()) else lo
	if pool.is_empty():
		pool = slots
	return pool[rnd.range_i(pool.size())]
