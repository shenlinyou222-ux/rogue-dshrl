# Room —— 房间模板（房间内部的可达性在这里被保证）
#
# 结构（一个房间就是一屏，左右无缝接缝）：
#
#   row 0                      实心天花板（玩家不能跳出房间）
#   rows 1..G-1                开阔空间；可放「上层平台 / 跳台梯」
#   row G                      主走廊地面（相邻列高差 <= 1）
#   rows G+1..h-1              实心大地
#
#   左端 / 右端：**没有竖墙**，门段是「一块 >= 96px 的连续平地」——
#   跨房间的行进因此退化成「走平地」（地图方案 §4.4 最省事的一刀），
#   跳跃可达性只需要在房间**内部**验证。
#
# 关键不变量（每一条都有断言，违反即报错而不是「带病工作」）：
#   R1 门段脚下连续平地 >= 6 格（96 px），且门段上方 >= 2 格净空
#   R2 主走廊相邻列高差 <= 1 格（不变量 B）
#   R3 入口 ↔ 出口**互相**可达（不许出现单向陷阱）
#   R4 所有内容槽（上层平台 / 跳台顶）从入口可达（G2）
#   R5 地图最后一行不得出现可站立格（封死「底部平行通道」后门）

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const VM = preload("res://gen/voxel_map.gd")
const MK = preload("res://gen/motion_kernel.gd")
const Rng = preload("res://core/rng.gd")
const Dig = preload("res://core/digest.gd")

const SIDE_W := "W"
const SIDE_E := "E"
const SIDE_T := "T"
const SIDE_B := "B"

# --------------------------------------------------------------------------
# 门段（DoorSpan）—— 门不再是「一格」，而是平台上某个可以走出去的高度范围
# --------------------------------------------------------------------------

class DoorSpan:
	var side: String = SIDE_W
	var x: int = 0             # 门所在的界列（房间内的 x）
	var floor_row: int = 0     # 脚下地面那一行
	var head_rows: int = 2     # 上方净空格数
	var run: int = 0           # 脚下连续平地长度（格）

	func floor_y_px() -> int:
		return floor_row * int(Cfg.PHY["tile"])

	func top_row() -> int:
		return floor_row - head_rows

	func to_dict() -> Dictionary:
		return {"side": side, "x": x, "floor_row": floor_row,
				"head_rows": head_rows, "run": run}

# --------------------------------------------------------------------------
# 规格与产物
# --------------------------------------------------------------------------

class RoomSpec:
	var rid: String = "room"
	var rtype: String = "normal"
	var w: int = 52
	var h: int = 34
	var seed64: int = 1
	var version_key: String = ""
	var entry_row: int = 24        # 入口门脚下地面行
	var exit_row: int = 24         # 出口门脚下地面行
	var door_run: int = 6          # 门段连续平地格数（>= 96px）
	var with_gallery: bool = true
	var platform_budget: int = 3
	var spike_chance: int = 12
	var variation: int = 2         # 主走廊地面起伏幅度（格）

class RoomVariant:
	var rid: String = ""
	var rtype: String = "normal"
	var w: int = 0
	var h: int = 0
	var map = null                 # VoxelMap
	var ground: Array = []         # 每列地面行
	var doors: Dictionary = {}     # side -> DoorSpan
	var entry: Vector2i = Vector2i(-1, -1)
	var exit_cell: Vector2i = Vector2i(-1, -1)
	var slots: Array = []          # 内容槽（都在可达集内）
	var gallery_cells: Array = []
	var platform_cells: Array = []
	var hazard_cells: Array = []
	var sealed_cells: Array = []       # 净空修复时被填实的柱子（调试/自检用）
	var errors: Array = []

	func fingerprint() -> String:
		return map.fingerprint()

	func door(side: String):
		return doors.get(side, null)

	func slot_count() -> int:
		return slots.size()

# --------------------------------------------------------------------------
# 构造
# --------------------------------------------------------------------------

static func build(spec: RoomSpec) -> Object:
	var kernel = MK.get_kernel()
	var v := RoomVariant.new()
	v.rid = spec.rid
	v.rtype = spec.rtype
	v.w = spec.w
	v.h = spec.h
	var w: int = spec.w
	var h: int = spec.h
	var dr: int = clampi(spec.door_run, 6, maxi(6, w / 3))
	var entry_row: int = clampi(spec.entry_row, 6, h - 4)
	var exit_row: int = clampi(spec.exit_row, 6, h - 4)
	var rnd = Rng.stream(spec.version_key, spec.seed64, 0, "room:" + spec.rid, "v1")

	# ---------------- 地面高度场 ----------------
	# 两端强制平（门段），中段允许 ±variation 起伏但逐列 <= 1（不变量 B）
	var ground := []
	var lo: int = mini(entry_row, exit_row)
	var hi: int = maxi(entry_row, exit_row)
	for x in range(w):
		var t := 0.0
		if w > 1:
			t = float(x) / float(w - 1)
		var target: int = int(round(float(entry_row) + float(exit_row - entry_row) * t))
		var gp: int = target + rnd.range_lo_hi(-spec.variation, spec.variation)
		gp = clampi(gp, maxi(lo, hi) - spec.variation, mini(h - 3, mini(lo, hi) + spec.variation))
		ground.append(gp)
	# 两端门段拍平
	for x in range(0, mini(dr + 1, w)):
		ground[x] = entry_row
	for x in range(maxi(0, w - dr - 1), w):
		ground[x] = exit_row
	# 逐列夹取（正向 + 反向），保证不变量 B
	for pass_i in range(2):
		var prev: int = -1
		var xs: Array = range(w) if pass_i == 0 else range(w - 1, -1, -1)
		for x in xs:
			if prev >= 0 and absi(int(ground[x]) - prev) > 1:
				ground[x] = prev + (1 if int(ground[x]) > prev else -1)
			ground[x] = clampi(int(ground[x]), 3, h - 2)
			prev = int(ground[x])
	# 再拍平一次门段（夹取可能把它动了，而门段平的是硬约束）
	for x in range(0, mini(dr + 1, w)):
		var d0: int = int(ground[x]) - entry_row
		ground[x] = entry_row
		# 让相邻列也能接上：从门段末端向外逐列修正
		var xx: int = dr + 1
		while xx < w and absi(int(ground[xx]) - int(ground[xx - 1])) > 1:
			ground[xx] = int(ground[xx - 1]) + (1 if int(ground[xx]) > int(ground[xx - 1]) else -1)
			xx += 1
	for x in range(maxi(0, w - dr - 1), w):
		ground[x] = exit_row
	var xx2: int = w - dr - 2
	while xx2 >= 0 and absi(int(ground[xx2]) - int(ground[xx2 + 1])) > 1:
		ground[xx2] = int(ground[xx2 + 1]) + (1 if int(ground[xx2]) > int(ground[xx2 + 1]) else -1)
		xx2 -= 1

	# ---------------- 矩阵 ----------------
	var grid: Array = []
	for y in range(h):
		var row := PackedStringArray()
		row.resize(w)
		for x in range(w):
			row[x] = VM.SOLID if (y == 0 or y >= int(ground[x])) else VM.EMPTY
		grid.append(row)

	v.ground = ground

	# ---------------- 上层平台 + 跳台梯 ----------------
	# 跳台梯：每级向上 3 格、水平 2 格（dh=48px <= h_single=122.5px，安全）
	if spec.with_gallery and w >= 40:
		_build_gallery(grid, v, spec, rnd)

	# ---------------- 浮空平台 ----------------
	var placed := 0
	var tries := 0
	while placed < spec.platform_budget and tries < 40:
		tries += 1
		var pw: int = 2 + rnd.range_i(3)
		var px0: int = 4 + rnd.range_i(maxi(1, w - 8 - pw))
		if not _flat_span(ground, px0 - 1, px0 + pw + 1):
			continue
		if _overlaps_any(v.platform_cells, px0 - 2, px0 + pw + 1):
			continue
		if _overlaps_any(v.gallery_cells, px0 - 2, px0 + pw + 1):
			continue
		var up: int = 4 + rnd.range_i(3)      # 4~6 格高（**至少 4**：3 格时下方只有
		                                      # 2 行净空 = 28px 高的玩家掉进去跳不出来，
		                                      # 实测这就是"玩家卡在一个小洞里再也不动"的根因）
		var py: int = int(ground[px0]) - up
		if py < 6:
			continue
		for x in range(px0, px0 + pw):
			grid[py][x] = VM.SOLID
			if py - 1 >= 1:
				grid[py - 1][x] = VM.EMPTY
			v.platform_cells.append(Vector2i(x, py))
		placed += 1

	# ---------------- 尖刺（危险格：踩了掉血，不是过不去） ----------------
	# 公平性规则：尖刺**不能贴着高度变化**（±1 台阶）。贴着台阶放刺 =
	# 「踩了刺还必须原地起跳越过台阶」，读得出躲不掉，是纯粹的挫败。
	# 机器人实测在这里卡死过：站在刺上，前方一格是台阶，翻滚出不去。
	var spike_run := 0
	for x in range(3, w - 3):
		if spike_run >= 1:
			spike_run = 0
			continue
		if int(ground[x]) != int(ground[x - 1]) or int(ground[x]) != int(ground[x + 1]):
			continue
		if rnd.chance(spec.spike_chance):
			grid[int(ground[x]) - 1][x] = VM.DANGER
			v.hazard_cells.append(Vector2i(x, int(ground[x]) - 1))
			spike_run += 1
		else:
			spike_run = 0

	# ---------------- 净空修复（"进得去出不来"的口袋） ----------------
	# 规则：任何可站立的地面，上方必须有 **至少 3 行净空**。
	#   玩家高 28px；要爬出一格台阶需要 16px 的上升空间 ⇒ 需要 28+16 = 44px = 2.75 格。
	#   留 3 行（48px）就是"一定能自己跳出来"的最小值。
	# 不足就把这段空行**填实**（宁可变成墙，也不要变成捕鼠笼）。
	# 实测事故：平台下方留了 2 行净空，玩家掉进去后跳不动、走不动、也出不来。
	var sealed_cols: Array = []
	for x in range(1, w - 1):
		var gy: int = int(ground[x])
		var above: int = gy - 1
		while above >= 1 and grid[above][x] != VM.SOLID:
			above -= 1
		if gy - 1 - above >= 3:
			continue
		for y in range(above + 1, gy):
			grid[y][x] = VM.SOLID
		sealed_cols.append(Vector2i(x, above + 1))
	if not sealed_cols.is_empty():
		v.sealed_cells = sealed_cols
		var keep: Array = []
		for hc in v.hazard_cells:
			if grid[hc.y][hc.x] != VM.SOLID:
				keep.append(hc)
		v.hazard_cells = keep

	# ---------------- 门段标记 ----------------
	var entry_x: int = 0
	var exit_x: int = w - 1
	var d_in := DoorSpan.new()
	d_in.side = SIDE_W
	d_in.x = entry_x
	d_in.floor_row = int(ground[entry_x])
	d_in.head_rows = Cfg.GEN["door_headroom"]
	d_in.run = dr
	var d_out := DoorSpan.new()
	d_out.side = SIDE_E
	d_out.x = exit_x
	d_out.floor_row = int(ground[exit_x])
	d_out.head_rows = Cfg.GEN["door_headroom"]
	d_out.run = dr
	v.doors[SIDE_W] = d_in
	v.doors[SIDE_E] = d_out

	v.entry = Vector2i(entry_x, int(ground[entry_x]) - 1)
	v.exit_cell = Vector2i(exit_x, int(ground[exit_x]) - 1)

	var map = VM.from_strings(grid)
	map.spawn = v.entry
	map.goal = v.exit_cell
	v.map = map

	# ---------------- 内容槽 ----------------
	var reach: Dictionary = map.reach_from(kernel, v.entry, true)
	# 槽位来源：上层平台顶、跳台顶、主走廊（避开门口 6 格与尖刺）
	for c in v.gallery_cells:
		var s := Vector2i(c.x, c.y - 1)
		if reach.has(s) and not v.hazard_cells.has(s):
			v.slots.append(s)
	# 平台顶（每隔一格取一个，避免敌人叠在一起）
	var pi := 0
	while pi < v.platform_cells.size():
		var c2: Vector2i = v.platform_cells[pi]
		var s2 := Vector2i(c2.x, c2.y - 1)
		if reach.has(s2):
			v.slots.append(s2)
		pi += 2
	# 主走廊
	var cx := 3
	while cx < w - 3:
		var s3 := Vector2i(cx, int(ground[cx]) - 1)
		if reach.has(s3) and not v.hazard_cells.has(s3):
			v.slots.append(s3)
		cx += 5
	v.slots = _dedup(v.slots)

	# ---------------- 断言 ----------------
	var errs := verify(v, kernel, spec)
	v.errors = errs
	return v

# --------------------------------------------------------------------------
# 断言（每一条都返回可读的原因，不 push_error —— 让调用方决定怎么处理）
# --------------------------------------------------------------------------

static func verify(v, kernel, spec) -> Array:
	var errs: Array = []
	var w: int = v.w
	var h: int = v.h
	var dr: int = clampi(spec.door_run, 6, maxi(6, w / 3))

	# R1 门段：脚下连续平地 >= 96px
	for side in [SIDE_W, SIDE_E]:
		var d = v.doors[side]
		var x0: int = 0 if side == SIDE_W else w - 1
		var run := 0
		var step: int = 1 if side == SIDE_W else -1
		var x: int = x0
		while x >= 0 and x < w:
			if int(v.ground[x]) == d.floor_row:
				run += 1
			else:
				break
			x += step
		if run * int(Cfg.PHY["tile"]) < int(Cfg.GEN["door_floor_min_px"]):
			errs.append("R1 %s 门段脚下平地只有 %d px（< %d）" % [side, run * 16, Cfg.GEN["door_floor_min_px"]])
		# 门前净空
		for k in range(1, int(Cfg.GEN["door_headroom"]) + 1):
			if v.map.is_blocked(x0, d.floor_row - k):
				errs.append("R1 %s 门段上方净空不足（row %d 被挡）" % [side, d.floor_row - k])

	# R2 不变量 B
	for x in range(1, w):
		if absi(int(v.ground[x]) - int(v.ground[x - 1])) > 1:
			errs.append("R2 x=%d 与邻列高差 %d > 1" % [x, absi(int(v.ground[x]) - int(v.ground[x - 1]))])
			break

	# R3 入口 ↔ 出口互相可达
	var fwd: Dictionary = v.map.reach_from(kernel, v.entry, true)
	if not fwd.has(v.exit_cell):
		errs.append("R3 入口 → 出口不可达")
	var back: Dictionary = v.map.reach_from(kernel, v.exit_cell, false)
	if not back.has(v.entry):
		errs.append("R3 出口 → 入口不可达（单向陷阱）")

	# R4 内容槽必须可达
	var unreachable := 0
	for s in v.slots:
		if not fwd.has(s):
			unreachable += 1
	if unreachable > 0:
		errs.append("R4 有 %d 个内容槽从入口不可达" % unreachable)

	# R5 地图最后一行不得可站立
	for x in range(w):
		if v.map.standable(x, h - 1):
			errs.append("R5 地图最后一行出现可站立格（底部平行通道后门）")
			break

	# R6 净空：任何可站立格上方必须有 >= 2 行净空（否则玩家掉进去出不来）。
	#   推导：站立格 y 的脚底在 (y+1)*16；身高 28px ⇒ 头在 y-1 行（需要 y-1 空）；
	#   跳出一格台阶要上升 16px ⇒ 头到 y-2 行（需要 y-2 空）。
	#   生成侧的"填实"修复留 3 行（y-1..y-3 空），比硬要求多 1 行余量。
	var low := 0
	var samples: Array = []
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			if not v.map.standable(x, y):
				continue
			if v.map.is_blocked(x, y - 1) or v.map.is_blocked(x, y - 2):
				low += 1
				if samples.size() < 4:
					samples.append("(%d,%d)" % [x, y])
	if low > 0:
		errs.append("R6 有 %d 个可站立格上方净空不足 2 格（会形成捕鼠笼）例：%s"
			% [low, str(samples)])
	return errs

# --------------------------------------------------------------------------
# 上层平台（gallery）：一跳一跳上去，从另一头跳下来 —— 房间内部的环
# --------------------------------------------------------------------------

static func _build_gallery(grid: Array, v, spec, rnd) -> void:
	var w: int = spec.w
	var base_x: int = 6 + rnd.range_i(3)
	var g0: int = int(v.ground[base_x])
	var up_steps := 3
	var step_up := 4                       # 每级向上 4 格：见下方"净空"注释
	var step_dx := 3                       # 每级水平 3 格（48px <= 上跳水平可达）
	var top_row: int = g0 - up_steps * step_up
	if top_row < 8:
		return
	var cx: int = base_x + step_dx * up_steps
	var gw_max: int = w - cx - 3
	if gw_max < 8:
		return
	# 跳台梯：从入口侧往上爬（每级 2 格宽，站上去绰绰有余）
	var cur_row: int = g0 - step_up
	var lx: int = base_x
	for k in range(up_steps):
		for x in range(lx, lx + 2):
			if x >= 1 and x < w - 1 and cur_row >= 2:
				grid[cur_row][x] = VM.SOLID
				grid[cur_row - 1][x] = VM.EMPTY
				v.platform_cells.append(Vector2i(x, cur_row))
		cur_row -= step_up
		lx += step_dx
	# 上层长廊（尽头是空的，玩家从那一头可以直接跳回主走廊 —— 房间内部的环）
	var gw: int = clampi(w / 2, 8, gw_max)
	for x in range(cx, cx + gw):
		grid[top_row][x] = VM.SOLID
		grid[top_row - 1][x] = VM.EMPTY
		v.gallery_cells.append(Vector2i(x, top_row))

# --------------------------------------------------------------------------
# 小工具
# --------------------------------------------------------------------------

## [x0, x1) 区间的地面是否全平（用来保证平台能站、门段能走）
static func _flat_span(ground: Array, x0: int, x1: int) -> bool:
	var a: int = maxi(1, x0)
	var b: int = mini(ground.size() - 2, x1)
	if b - a < 2:
		return false
	for x in range(a, b):
		if int(ground[x]) != int(ground[a]):
			return false
	return true

## 这批格子的 x 是否落在 [x0, x1) 内（避免平台互相重叠）
static func _overlaps_any(cells: Array, x0: int, x1: int) -> bool:
	for c in cells:
		if c.x >= x0 and c.x < x1:
			return true
	return false

static func _dedup(cells: Array) -> Array:
	var seen := {}
	var out: Array = []
	for c in cells:
		var k := "%d,%d" % [c.x, c.y]
		if seen.has(k):
			continue
		seen[k] = true
		out.append(c)
	return out
