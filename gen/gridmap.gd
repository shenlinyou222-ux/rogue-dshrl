# GridMap —— 走廊生成 + 机关（单调布尔加）
#
# 生成一张地图 —— **构造性保证连通**，不做「生成-校验-重试」。
#
# 两阶段（这是关键，混在一起就出 bug）：
#   阶段 1 走廊：地面高度场相邻列高差 <= 1 格（不变量 B）；缺口宽度由核容量表决定；
#                走廊上方 clearance 格永久留空。
#                => 由核表直接可证：整条走廊**双向连通**。
#   阶段 2 装饰：只在走廊**上方**雕刻空腔 / 浮空平台 / 尖刺，绝不触碰走廊本体。
#
# 机关不是「子矩阵替换」，而是「单调布尔加」：
#   门开着 = 若干格由阻挡变通行。因此 R_关 ⊆ R_开 可证，不动点唯一、
#   与触发顺序无关、永远可判定。求解 = 反复「捡道具 → 触发机关 → 重算闭包」。

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const VM = preload("res://gen/voxel_map.gd")
const MK = preload("res://gen/motion_kernel.gd")
const Rng = preload("res://core/rng.gd")

# --------------------------------------------------------------------------
# 机关
# --------------------------------------------------------------------------

## 机关 = 生产规则：前提条件成立 ⟹ 新增可通行格 / 新增边。
## kind: door（钥匙门）/ shortcut（背面开关）/ gate（能力门）
class Mechanism:
	var mid: String = ""
	var kind: String = "door"
	var pass_cells: Array = []          # 打开时变成可通行
	var edge_adds: Array = []           # 打开时新增的边 [ [src, dst], ... ]
	var key_item = null                 # 需要拾取的道具
	var need_region = null              # 需要先到达某格（背面开关）
	var arena = null                    # (x0, x1) 作用域
	var need_capability = null
	var desc: String = ""

	func _init(p_mid: String = "", p_kind: String = "door") -> void:
		mid = p_mid
		kind = p_kind

	func to_dict() -> Dictionary:
		return {
			"mid": mid, "kind": kind, "desc": desc,
			"pass_cells": pass_cells.size(),
			"key_item": key_item,
			"need_region": need_region,
			"need_capability": need_capability,
		}

# --------------------------------------------------------------------------
# 世界（base 矩阵 + 机关集合）
# --------------------------------------------------------------------------

class World:
	var base                        # VoxelMap
	var kernel
	var mechanisms: Array = []
	var items: Dictionary = {}      # 道具名 -> Vector2i
	var targets: Array = []         # 必须可达的格子

	func _init(p_base, p_kernel) -> void:
		base = p_base
		kernel = p_kernel

	## 最小不动点求解：反复触发机关直到没有新的可触发。
	## collect=false 时不拾取任何道具 —— 用来问「基础地图本身就通吗」。
	func solve(forward_only: bool = true, activated: Array = [],
			   collect: bool = true) -> Dictionary:
		var forced := {}
		for a in activated:
			forced[a] = true
		var opened := {}
		var taken := {}
		var cur = base
		var trace: Array = []
		var rounds := 0
		var max_rounds: int = mechanisms.size() + 2

		while rounds <= max_rounds:
			rounds += 1
			var reach: Dictionary = cur.reach_from(kernel, cur.spawn, forward_only)

			if collect:
				for name in items.keys():
					if taken.has(name):
						continue
					var cell: Vector2i = items[name]
					if reach.has(cell) or _near(reach, cell, 1):
						taken[name] = true
						trace.append("拾取道具 %s @%s" % [name, str(cell)])

			var progressed := false
			for mech in mechanisms:
				if opened.has(mech.mid):
					continue
				if not _cond_ok(mech, reach, taken, forced):
					continue
				opened[mech.mid] = true
				if not mech.pass_cells.is_empty():
					cur = cur.open_cells(mech.pass_cells)
				trace.append("触发机关 %s（%s）：%s" % [mech.mid, mech.kind, mech.desc])
				progressed = true
			if not progressed:
				break

		var reach2: Dictionary = cur.reach_from(kernel, cur.spawn, forward_only)
		var unreachable: Array = []
		for t in targets:
			if not reach2.has(t):
				unreachable.append(t)
		return {
			"map": cur, "reach": reach2, "opened": opened, "taken": taken,
			"trace": trace, "unreachable": unreachable, "rounds": rounds,
			"ok": unreachable.is_empty(),
		}

	func _near(reach: Dictionary, cell: Vector2i, r: int) -> bool:
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if reach.has(Vector2i(cell.x + dx, cell.y + dy)):
					return true
		return false

	func _cond_ok(mech, reached: Dictionary, taken: Dictionary, forced: Dictionary) -> bool:
		if forced.has(mech.mid):
			return true
		if mech.key_item != null and not taken.has(mech.key_item):
			return false
		if mech.need_region != null:
			if not _near(reached, mech.need_region, 2):
				return false
		if mech.need_capability != null:
			return false      # 能力门需要玩家已获得该能力
		return true

	## 关键机关：摘掉它目标就不可达。
	func critical() -> Array:
		var full = solve()
		var out: Array = []
		for mech in mechanisms:
			var saved := mechanisms
			mechanisms = []
			for x in saved:
				if x.mid != mech.mid:
					mechanisms.append(x)
			var r = solve()
			mechanisms = saved
			if not r["unreachable"].is_empty():
				out.append(mech.mid)
		return out

	func redundant() -> Array:
		var crit := {}
		for c in critical():
			crit[c] = true
		var out: Array = []
		for x in mechanisms:
			if not crit.has(x.mid):
				out.append(x.mid)
		return out

	## 捷径收益：开门前 / 开门后 src→dst 的最短步数（-1 表示不可达）。
	## 「开门前」的基准必须是**原始矩阵** base，不是 solve() 的结果 ——
	## solve 会把无前置条件的机关直接打开，拿它当基准收益永远算成 0。
	func shortcut_gain(src: Vector2i, dst: Vector2i, forward_only: bool = true) -> Vector2i:
		var before: int = base.bfs_dist(kernel, src, dst, forward_only)
		var after: int = solve(false, [], true)["map"].bfs_dist(kernel, src, dst, forward_only)
		return Vector2i(before, after)

# --------------------------------------------------------------------------
# 生成参数与报告
# --------------------------------------------------------------------------

class GenSpec:
	var w: int = 96
	var h: int = 34
	var seed64: int = 20260101
	var step_chance: int = 100          # 每列改变高度的概率（%）
	var max_step: int = 1
	var gap_chance: int = 22
	var gap_min: int = 1
	var gap_max: int = 1
	var gap_spacing: int = 6
	var corridor_clearance: int = 2
	var chamber_chance: int = 30
	var chamber_min_w: int = 6
	var chamber_max_w: int = 13
	var chamber_min_h: int = 5
	var chamber_max_h: int = 9
	var platform_chance: int = 55
	var danger_chance: int = 10
	var floor_base: int = 24
	var with_mechanisms: bool = true
	var rng_head: String = "corridor"

class GenReport:
	var spec
	var height: Array = []
	var gaps: Array = []
	var repairs: Array = []
	var errors: Array = []
	var trap_filled: int = 0

# --------------------------------------------------------------------------
# 由核算出的容量（缺口宽度、障碍连排）
# --------------------------------------------------------------------------

## 跨过 λ 格宽的缺口需要水平位移 λ+1 格；必须**双向**都允许。
static func gap_capacity(kernel) -> Dictionary:
	return kernel.gap_capacity()

static func max_crossable_barrier(kernel) -> int:
	return kernel.max_crossable_barrier()

## 选尖刺列，**强制**每段连续尖刺不超过 max_run 格（约束在生成时成立）。
static func pick_spike_columns(rnd, w: int, gap_cols: Dictionary,
							   chance: int, max_run: int,
							   x_lo: int = 3, x_hi: int = -1) -> Dictionary:
	var hi: int = (w - 4) if x_hi < 0 else x_hi
	var spikes := {}
	var run := 0
	for xx in range(x_lo, hi + 1):
		if gap_cols.has(xx):
			run = 0
			continue
		if run >= max_run:
			run = 0
			continue
		if rnd.chance(chance):
			spikes[xx] = true
			run += 1
		else:
			run = 0
	return spikes

# --------------------------------------------------------------------------
# 主生成
# --------------------------------------------------------------------------

static func generate(spec = null) -> Dictionary:
	if spec == null:
		spec = GenSpec.new()
	var kernel = MK.get_kernel()
	var rnd = Rng.from_seed(spec.seed64)
	var w: int = spec.w
	var h: int = spec.h
	var step: int = mini(spec.max_step, 1)
	var clearance: int = maxi(2, spec.corridor_clearance)
	var cap: Dictionary = gap_capacity(kernel)

	# ---------------- 阶段 1：高度场 ----------------
	# 缺口宽度按「跨缺口高差」查核容量表，所以顺序必须先高度、后缺口。
	var height: Array = []
	var y: int = spec.floor_base
	for xx in range(w):
		var d0: int = clampi(rnd.range_i(5) - 2, -step, step)
		if xx > 0 and rnd.range_i(100) >= spec.step_chance:
			d0 = 0
		y = clampi(y + d0, clearance + 3, h - 3)
		if xx > 0:
			y = clampi(y, height[xx - 1] - step, height[xx - 1] + step)
			y = clampi(y, clearance + 3, h - 3)
		height.append(y)

	var gaps: Array = []
	var x: int = 3
	while x < w - 4:
		if rnd.range_i(100) < spec.gap_chance:
			var dh_cells: int = absi(int(height[x - 1]) - int(height[x + 1]))
			var width: int = mini(spec.gap_max,
				maxi(spec.gap_min, rnd.range_i(2) + 1))
			width = mini(width, int(cap.get(dh_cells, 1)))
			width = maxi(1, width)
			gaps.append([x, width])
			x += width + maxi(3, spec.gap_spacing)
			continue
		x += 1

	var gap_cols := {}
	for g in gaps:
		for i in range(int(g[1])):
			gap_cols[int(g[0]) + i] = true

	# ---------------- 矩阵：地面 ----------------
	var grid := []
	for yy in range(h):
		var row := PackedStringArray()
		for xx in range(w):
			row.append(VM.EMPTY)
		grid.append(row)
	for xx in range(w):
		if gap_cols.has(xx):
			continue
		for yy in range(int(height[xx]), h):
			grid[yy][xx] = VM.SOLID

	# ---------------- 阶段 2：装饰（只在地面以上） ----------------
	x = 5
	while x < w - 8:
		if gap_cols.has(x):
			x += 1
			continue
		if rnd.range_i(100) < spec.chamber_chance:
			var cw: int = spec.chamber_min_w + rnd.range_i(spec.chamber_max_w - spec.chamber_min_w + 1)
			var ch: int = spec.chamber_min_h + rnd.range_i(spec.chamber_max_h - spec.chamber_min_h + 1)
			cw = maxi(2, mini(cw, w - 2 - x))
			for xx in range(x, mini(w, x + cw)):
				if gap_cols.has(xx):
					continue
				var top: int = maxi(1, int(height[xx]) - clearance - ch)
				for yy in range(top, int(height[xx]) - clearance):
					grid[yy][xx] = VM.EMPTY
			# 空腔里放浮空平台：平台顶面 = 走廊地面 - 3，且至少 2 格宽。
			# 随手取高度会造出孤立浮岛（侧向 3 格高差 + 1~2 格位移，核里没有这种边）。
			if rnd.range_i(100) < spec.platform_chance and cw >= 4:
				var px0: int = x + 1 + rnd.range_i(maxi(1, cw - 3))
				var pw: int = 2 + rnd.range_i(2)
				var py: int = int(height[px0]) - 3
				for xx in range(px0, mini(x + cw, px0 + pw)):
					if gap_cols.has(xx) or not (py >= 0 and py < h):
						continue
					grid[py][xx] = VM.SOLID
					if py - 1 >= 0:
						grid[py - 1][xx] = VM.EMPTY
			x += cw + 2
		else:
			x += 1

	# 尖刺：连续长度由核算出的上限约束（危险格不可站立，连排太长等于切断走廊）
	var max_run: int = max_crossable_barrier(kernel)
	var spike_cols: Dictionary = pick_spike_columns(rnd, w, gap_cols,
		spec.danger_chance, max_run)
	for xx in spike_cols.keys():
		grid[int(height[xx]) - 1][xx] = VM.DANGER

	# 缺口列填实到底（缺口是「一堵矮隔墙」，不是通到地图底部的竖井）
	for g in gaps:
		var gx: int = int(g[0])
		var gw: int = int(g[1])
		var neigh: Array = []
		for cc in [gx - 1, gx + gw]:
			if cc >= 0 and cc < w:
				neigh.append(int(height[cc]))
		var base_surface: int = (int(_max_of(neigh)) + 1) if not neigh.is_empty() else int(height[gx])
		for xx in range(gx, gx + gw):
			var surface: int = mini(h - 1, base_surface)
			if absi(surface - int(height[xx - 1])) > 1:
				surface = int(height[xx - 1]) + 1
			surface = mini(h - 1, surface)
			height[xx] = surface
			for yy in range(maxi(0, surface), h):
				grid[yy][xx] = VM.SOLID

	# ---------------- 阶段 3：收尾归一化（守门，不是抽奖） ----------------
	# 每一列的走廊地面必须正好是 height[x] 那一格，上面那一格必须空。
	# 只填不挖（与「机关只做单调加法」一致）。
	for xx in range(w):
		var gy: int = int(height[xx])
		if not (gy >= 2 and gy < h):
			continue
		for yy in range(1, gy):
			if grid[yy][xx] == VM.SOLID:
				grid[yy][xx] = VM.EMPTY
		for yy in range(gy, h):
			grid[yy][xx] = VM.SOLID

	# ---------------- 出生点 / 出口 ----------------
	var sp_x: int = 1
	while sp_x < w and gap_cols.has(sp_x):
		sp_x += 1
	var gl_x: int = w - 2
	while gl_x >= 0 and gap_cols.has(gl_x):
		gl_x -= 1
	var sp := Vector2i(sp_x, int(height[sp_x]) - 1)
	var gl := Vector2i(gl_x, int(height[gl_x]) - 1)
	grid[sp.y][sp.x] = VM.SPAWN
	grid[gl.y][gl.x] = VM.GOAL

	var map = VM.from_strings(grid)
	map.spawn = sp
	map.goal = gl
	var rep := GenReport.new()
	rep.spec = spec
	rep.height = height
	rep.gaps = gaps

	# ---------------- 断言：双向连通（守门，不是修复） ----------------
	map = enforce_bidirectional(map, kernel, rep)
	assert_corridor_connected(map, kernel, rep, spec)
	return {"map": map, "report": rep}

static func _max_of(arr: Array) -> int:
	var m: int = -2147483648
	for v in arr:
		m = maxi(m, int(v))
	return m

# --------------------------------------------------------------------------
# 不变量 B：双向夹取
# --------------------------------------------------------------------------

static func enforce_bidirectional(m, kernel, rep) -> Object:
	var grid: Array = VM.mutable_rows(m.cells)
	var h: int = m.h
	var w: int = m.w

	# 这一列的走廊地面是哪个格（**从矩阵直接读**，不信 rep.height）
	var _ground_of = func(xx: int) -> int:
		var y0: int = maxi(0, int(rep.height[xx]) - 1)
		for y in range(y0, mini(h, int(rep.height[xx]) + 3)):
			if grid[y][xx] == VM.SOLID:
				return y
		for y in range(0, h):
			if grid[y][xx] == VM.SOLID:
				return y
		return -1

	var _clamp = func(newgy: int, gy: int, xx: int, tag: String) -> int:
		for y in range(1, h):
			grid[y][xx] = VM.EMPTY
		for y in range(newgy, h):
			grid[y][xx] = VM.SOLID
		rep.repairs.append("不变量B%s: x=%d 地面 %d -> %d" % [tag, xx, gy, newgy])
		rep.height[xx] = newgy
		return newgy

	# 正向夹取
	var prev: int = -1
	for xx in range(w):
		var gy: int = int(_ground_of.call(xx))
		if gy < 0:
			continue
		if prev >= 0 and absi(gy - prev) > 1:
			var target: int = prev + (1 if gy > prev else -1)
			gy = int(_clamp.call(clampi(target, 2, h - 2), gy, xx, ""))
		prev = gy

	# **反向再夹一遍** —— 单向夹取漏掉「连续下坡从右往左看是悬崖」那一半。
	prev = -1
	for xx in range(w - 1, -1, -1):
		var gy2: int = int(_ground_of.call(xx))
		if gy2 < 0:
			continue
		if prev >= 0 and absi(gy2 - prev) > 1:
			var target2: int = prev + (1 if gy2 > prev else -1)
			gy2 = int(_clamp.call(clampi(target2, 2, h - 2), gy2, xx, "(反向)"))
		prev = gy2

	# 守门：不变量 B 必须真的成立
	var viol: Array = []
	for xx in range(1, w - 1):
		if absi(int(rep.height[xx]) - int(rep.height[xx - 1])) > 1 \
				or absi(int(rep.height[xx]) - int(rep.height[xx + 1])) > 1:
			viol.append(xx)
	if not viol.is_empty():
		rep.errors.append("不变量 B 被破坏：列 %s 与邻列高差 > 1 格" % str(viol.slice(0, 5)))

	# 出生点 / 出口重新落到走廊地面上（不能落在浮空平台上）
	var old_spawn: Vector2i = m.spawn
	var old_goal: Vector2i = m.goal
	for old in [old_spawn, old_goal]:
		if old.x >= 0 and grid[old.y][old.x] in [VM.SPAWN, VM.GOAL]:
			grid[old.y][old.x] = VM.EMPTY

	var relocate_on_floor = func(cell: Vector2i, mark: String) -> Vector2i:
		if cell.x < 0:
			return cell
		var step_dir: int = 1 if cell.x >= w / 2 else -1
		var order: Array = [cell.x]
		var xx: int = cell.x
		for _i in range(8):
			xx += step_dir
			if xx >= 1 and xx < w - 1:
				order.append(xx)
		for cx in order:
			var gy: int = int(_ground_of.call(cx))
			if gy < 0 or not (gy >= 2 and gy < h):
				continue
			var y: int = gy - 1
			if grid[gy][cx] == VM.SOLID and (y < 0 or grid[y][cx] != VM.SOLID):
				grid[y][cx] = mark
				return Vector2i(cx, y)
		return cell

	var sp: Vector2i = relocate_on_floor.call(old_spawn, VM.SPAWN)
	var gl: Vector2i = relocate_on_floor.call(old_goal, VM.GOAL)
	var out = VM.from_strings(grid)
	out.spawn = sp
	out.goal = gl
	return out

# --------------------------------------------------------------------------
# 断言：走廊双向连通
# --------------------------------------------------------------------------

## 有两点必须说清楚，否则这个断言会给出**假的通过**：
##   1. **只看可站立格点**（walk_cells 把「只有走廊地面能站」显式化）；
##   2. **生成阶段不做重试** —— 失败是 bug 信号，不是「运气不好」。
## 返回 "" 表示通过，否则返回错误描述。
static func assert_corridor_connected(m, kernel, rep, spec = null) -> String:
	var wire = m.walk_cells(rep.height, {}).wall_edges()
	if wire.spawn.x < 0 or wire.goal.x < 0:
		var e0 := "生成器违反连通性不变量：出生点或出口不是可站立格点"
		rep.errors.append(e0)
		return e0
	var fwd: Dictionary = wire.reach_from(kernel, wire.spawn, true)
	if not fwd.has(wire.goal):
		var e1 := "生成器违反连通性不变量：出口 %s 沿走廊不可达（seed=%d）" % [str(m.goal), rep.spec.seed64]
		rep.errors.append(e1)
		return e1
	# 回程必须允许向左的边（dcx<0），否则结构上永远判不出来
	var back: Dictionary = wire.reach_from(kernel, wire.goal, false)
	if not back.has(wire.spawn):
		var e2 := "生成器违反**双向**连通不变量：出口回不到出生点（seed=%d）" % rep.spec.seed64
		rep.errors.append(e2)
		return e2
	return ""

# --------------------------------------------------------------------------
# 机关布点
# --------------------------------------------------------------------------

## 在矩阵上布机关 —— 全部表现为「某些格 0→1 通行」。
##
## 门 D 把走廊某一列堵死：该列地面以上直到天花板全部实心，其中走廊净空的
## 6 格是「门」（关闭时阻挡、打开时通行）。
##
## 为什么必须把门以上直到天花板也封死：否则玩家从上面一格格爬过去就把门
## 绕开了（原型实测可达，门会变成完全冗余）。
##
## ⚠️ **一条在 1 维走廊上被实测逼出来的设计约束**：
## 「背面开关捷径」在一维走廊里**必然死锁** —— 捷径把唯一通路封死，
## 而它的触发点在封死点另一端，玩家永远到不了触发点（实测 10/16 个种子卡死，
## 可达集停在封列前一格）。真正的「背面开关 / 抄近路」需要**平行通路**
## （房间层的支线房间才提供）。所以这里布的是**跨楼层的进度链**：
##
##     出生点 → [钥匙] → [门1] → [开关] → [门2] → 出口
##
## 两个门都是**关键机关**（摘掉任一个出口即不可达），且**无死锁**
## （每个门的前置条件都在它自己之前）。
## 陷阱剪除（"进得去出不来"的治本手段）
##
## 判据（有向可达，不是无向连通）：
##   F = 从出生格**走得到**的所有站立格
##   B = 所有**能走到终点**的站立格（把步长取反做 BFS）
##   F \ B = 能走进去、但进去之后再也没法通关的格子 → 填实
##
## 为什么必须用有向：本作有"跳下去容易、爬上来难"，落到凹槽里就回不去了。
## 为什么填实是安全的：陷阱格里不可能存在"通往终点的路"的中间节点
##   （否则那个格子自己就能到终点），所以填掉它不可能切断出生点→终点的路。
## 计算时**把所有门当作已开**，否则门后那一整段都会被误判成陷阱。
static func prune_traps(m, kernel, protected_cells: Array, report = null) -> int:
	var open_map = m.clone()
	# 把所有 D（关闭的门）当作开着再算可达性
	var all_doors: Array = []
	for y in range(m.h):
		var row: String = m.cells[y]
		for x in range(m.w):
			if row[x] == VM.DOOR:
				all_doors.append(Vector2i(x, y))
	if not all_doors.is_empty():
		open_map = m.open_cells(all_doors)
	var spawn: Vector2i = m.spawn
	var goal: Vector2i = m.goal
	if spawn.x < 0 or goal.x < 0:
		return 0
	# 入口用**宽松**掩码、出口用**严格**掩码 —— 这不是笔误，是刻意的不对称：
	#   * 宽松（"上下都实心才算墙"）会高估玩家能到达的地方（天花板挡不住"核"），
	#     正是运行时靠贴墙滑行、踩平台边角能溜进去的那些格；
	#   * 严格（任何实心格都挡人）会低估玩家能离开的地方。
	# 于是 宽松可达 \ 严格可离开 = **进得去、出不来**的真正陷阱区（含模型看不见的入口）。
	# 用两次宽松（原来那样）会漏掉这一整类陷阱，无头机器人就是掉进这类坑里卡死的。
	var f: Dictionary = open_map.reach_from(kernel, spawn, false)
	if f.is_empty():
		return 0
	var b: Dictionary = open_map.reach_back_from(kernel, goal, true)
	var keep: Dictionary = {}
	for c in protected_cells:
		keep["%d,%d" % [c.x, c.y]] = true
	var filled := 0
	var grid: Array = VM.mutable_rows(m.cells)
	for key in f.keys():
		if b.has(key):
			continue
		var c: Vector2i = key
		if keep.has("%d,%d" % [c.x, c.y]):
			continue
		if c.x <= 0 or c.x >= m.w - 1 or c.y <= 1 or c.y >= m.h - 1:
			continue
		if m.cells[c.y][c.x] == VM.SOLID:
			continue
		grid[c.y][c.x] = VM.SOLID
		filled += 1
	if filled > 0:
		# 回写（mutable_rows 是副本 → 写回 m 的 cells/blocked）
		var rows := PackedStringArray()
		for y in range(m.h):
			rows.append("".join(grid[y]))
		m.apply_rows(rows)
	if report != null:
		report.trap_filled = filled
	return filled

static func place_mechanisms(m, spec, report, key_side: String = "near") -> Object:
	var kernel = MK.get_kernel()
	var grid: Array = VM.mutable_rows(m.cells)
	var h: int = m.h
	var w: int = m.w
	var height: Array = report.height
	var rnd = Rng.from_seed(spec.seed64 ^ 0x5EED)

	# 门列：必须在走廊上、地面平坦（否则门会嵌在斜坡里，身体过不去）
	var cand: Array = []
	for xx in range(6, w - 6):
		if absi(int(height[xx]) - int(height[xx - 1])) > 1:
			continue
		if absi(int(height[xx]) - int(height[xx + 1])) > 1:
			continue
		cand.append(xx)
	if cand.size() < 4:
		var bare := World.new(m, kernel)
		bare.targets = [m.goal]
		return bare

	var _pick = func(frac: float) -> int:
		return int(cand[clampi(int(cand.size() * frac), 0, cand.size() - 1)])

	var door1_x: int = _pick.call(0.45)
	var door2_x: int = _pick.call(0.78)
	if door2_x - door1_x < 8:
		door2_x = door1_x + 8
		if door2_x >= w - 4:
			door2_x = door1_x
	if door1_x < 8:
		door1_x = 8

	var _seal_column = func(xx: int, door_cells: Array) -> void:
		for yy in range(1, int(height[xx])):
			grid[yy][xx] = VM.SOLID
		for c in door_cells:
			grid[c.y][c.x] = VM.DOOR

	var _door_cells = func(xx: int) -> Array:
		var out: Array = []
		for k in range(6):
			var yy: int = int(height[xx]) - 1 - k
			if yy >= 1:
				out.append(Vector2i(xx, yy))
		return out

	var world := World.new(null, kernel)

	# ---- 门 1：钥匙门（钥匙在它之前的主路径上）----
	var d1_cells: Array = _door_cells.call(door1_x)
	_seal_column.call(door1_x, d1_cells)
	var key_x: int = door1_x - 6
	if key_x < 2:
		key_x = door1_x + 6
	var key_cell := Vector2i(key_x, int(height[key_x]) - 1)
	grid[key_cell.y][key_cell.x] = VM.KEY
	var door := Mechanism.new("door_key", "door")
	door.pass_cells = d1_cells
	door.key_item = "key"
	door.arena = [mini(key_x, door1_x), door1_x]
	door.desc = "钥匙门 @x=%d（钥匙在 x=%d）" % [door1_x, key_x]
	world.mechanisms.append(door)
	world.items["key"] = key_cell

	# ---- 门 2：背面开关门（开关在门 1 与门 2 **之间**）----
	if door2_x > door1_x + 4:
		var d2_cells: Array = _door_cells.call(door2_x)
		_seal_column.call(door2_x, d2_cells)
		var sw_x: int = int((door1_x + door2_x) / 2)
		if absi(sw_x - door1_x) < 3:
			sw_x = door1_x + 3
		if absi(door2_x - sw_x) < 3:
			sw_x = door2_x - 3
		var sw_cell := Vector2i(sw_x, int(height[sw_x]) - 1)
		if sw_cell.x > door1_x and sw_cell.x < door2_x:
			grid[sw_cell.y][sw_cell.x] = VM.SWITCH
		var gate := Mechanism.new("gate_back_switch", "gate")
		gate.pass_cells = d2_cells
		gate.need_region = sw_cell
		gate.arena = [door1_x, door2_x]
		gate.desc = "背面开关门 @x=%d（开关在 x=%d，需先过门 1）" % [door2_x, sw_x]
		world.mechanisms.append(gate)

	var final = VM.from_strings(grid)
	final.spawn = m.spawn
	final.goal = m.goal
	world.base = final
	world.targets = [m.goal]
	return world
