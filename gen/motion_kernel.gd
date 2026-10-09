# MotionKernel —— 把跳跃物理「编译」成一组格偏移 K
#
# 核心思想（地图方案 §4.5）：
#   跳跃能力只取决于 (Δh, Δx)，**与地图无关**。
#   所以在启动时枚举所有 (Δh, Δx) 采样、跑真实的 can_jump，把通过的组合
#   烧成一个格偏移集合 K。之后地图的连通性计算**完全不碰物理**。
#
#   A[p] = { p + k | k ∈ K, walk(p), walk(p+k), 轨迹不穿墙 }
#   R    = A*      ← 布尔闭包，BFS ≡ Warshall
#
# 本实现相对原型多了一层优化：把「轨迹穿墙检查」预编译成**每偏移一张相对格掩码**。
# 轨迹检查的几何只依赖偏移（平移不变），所以掩码可以离线算一次，
# 运行时只需对掩码里的格做 wall 查询。

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const JP = preload("res://core/jump_phys.gd")

static var _singleton = null

## K 的格偏移集合（无 (0,0)、无重复、按 (dcy, dcx) 排序）。
var cells: Array = []
## dcy -> PackedInt32Array(dcx...)
var by_dcy: Dictionary = {}
## 偏移 -> 该偏移下「轨迹扫过的相对格」列表（Vector2i），这些格不能是墙。
var masks: Dictionary = {}
## 每个偏移对应的核桶信息（诊断）
var _diag: Dictionary = {}
var compiled_at_ms: int = 0

static func get_kernel():
	if _singleton == null:
		var s = load("res://gen/motion_kernel.gd")
		_singleton = s.new()
		_singleton._compile()
	return _singleton

static func reset_kernel() -> void:
	_singleton = null

# --------------------------------------------------------------------------
# 编译
# --------------------------------------------------------------------------

func _compile() -> void:
	var t0 := Time.get_ticks_msec()
	var dh_step: int = int(Cfg.KERNEL["dh_step"])
	var d: int = int(Cfg.KERNEL["d"])
	var tile_c: int = int(Cfg.PHY["tile"])
	var tile := float(tile_c)
	var ref_w := 2.0 * tile
	var half: int = tile_c / 2
	var max_rise: int = int(Cfg.KERNEL["max_rise"])
	var max_fall: int = int(Cfg.KERNEL["max_fall"])
	var forward_range: int = int(Cfg.KERNEL["forward_range"])

	var hi: int = (max_rise / dh_step) * dh_step          # 208
	var lo: int = -(max_fall / dh_step) * dh_step         # -304

	var hmax := JP.h_max()
	var fmax := JP.fall_max()

	var dcy_lo: int = int(floor(float(-(hi + half)) / tile))
	var dcy_hi: int = int(floor(float(max_fall + half) / tile))

	var out: Array = []
	var diag: Dictionary = {}

	for dcy in range(dcy_lo, dcy_hi + 1):
		var dh_lo: int = -dcy * tile_c - half
		var dh_hi: int = -dcy * tile_c + half
		if float(dh_lo) > hmax or float(dh_hi) < -fmax:
			continue
		var dh_fav: int = max(dh_lo, -int(fmax))
		var t_fav := JP.t_air(float(dh_fav))
		if t_fav >= JP.INF:
			continue
		var max_dcx: int = mini(forward_range,
			int((JP.reach_limit(t_fav, JP.vx_dash()) + ref_w) / tile) + 2)

		var ring: Array = []
		for dcx in range(-2, max_dcx + 1):
			var dx_lo: int = dcx * tile_c - half
			var dx_hi: int = dcx * tile_c + half
			var good := true
			var dh_v: int = dh_lo
			while dh_v <= dh_hi:
				if float(dh_v) > hmax or float(dh_v) < -fmax:
					good = false
					break
				var t := JP.t_air(float(dh_v))
				if t >= JP.INF:
					good = false
					break
				var rl := JP.reach_limit(t, JP.vx_dash())
				var dx_v: int = dx_lo
				while dx_v <= dx_hi:
					ring.append(dx_v)
					if absf(float(dx_v)) > rl or not _ref_can_jump(dh_v, dx_v, tile):
						good = false
						break
					dx_v += d
				if not good:
					break
				dh_v += dh_step
			if good and not (dcx == 0 and dcy == 0):
				out.append(Vector2i(dcx, dcy))
		diag[-dcy * tile_c] = ring

	out.sort_custom(func(a, b):
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)

	# 不变量：无重复、无 (0,0)
	var seen := {}
	for c in out:
		if c == Vector2i.ZERO:
			push_error("运动核不能含 (0,0)")
		if seen.has(c):
			push_error("运动核里有重复偏移 %s" % str(c))
		seen[c] = true

	cells = out
	_diag = diag

	by_dcy = {}
	for c in cells:
		if not by_dcy.has(c.y):
			by_dcy[c.y] = PackedInt32Array()
		var arr: PackedInt32Array = by_dcy[c.y]
		arr.append(c.x)
		by_dcy[c.y] = arr

	# 轨迹掩码预编译
	masks = {}
	for c in cells:
		masks[c] = _build_mask(c)

	compiled_at_ms = Time.get_ticks_msec() - t0

	# 构造后自检：查询接口必须与 cells 完全一致（历史上出过「幽灵数据」）
	var raw := {}
	for c in cells:
		if not raw.has(c.y):
			raw[c.y] = {}
		raw[c.y][c.x] = true
	for dcy in raw.keys():
		var got := {}
		for x in allowed_dcx(dcy):
			got[x] = true
		if got != raw[dcy]:
			push_error("运动核自检失败：dcy=%d 的 allowed_dcx 与 cells 不一致" % dcy)

## 参照几何下的 can_jump（源/目标各 2 格宽的平台，无其它实心块）。
## 只用于核编译 —— 真实地图的判定走 prefilter + 掩码。
func _ref_can_jump(dh: int, dx: int, tile: float) -> bool:
	var ref_w := 2.0 * tile
	var src := {"x0": 0.0, "y0": 1000.0, "x1": ref_w, "y1": 1000.0 + tile}
	var dst := {"x0": float(dx), "y0": 1000.0 - float(dh), "x1": float(dx) + ref_w,
				"y1": 1000.0 - float(dh) + tile}
	var r := JP.can_jump(src, dst, [], 9)
	return bool(r["ok"])

# --------------------------------------------------------------------------
# 轨迹掩码
# --------------------------------------------------------------------------

## 预编译「这一步跳跃的身体矩形扫过了哪些相对格」。
#
# 判据与原型 trajectory_clear 逐字一致：
#   * 脚底贴在格子的**下边界**（不是格心），留 1px 余量；
#   * 身体矩形 = [feet - BODY_H, feet] × [px ± BODY_HW]；
#   * **严格重叠**才算碰撞（边界相切不算）—— 否则站着都算穿墙；
#   * 两端格本身豁免。
func _build_mask(off: Vector2i) -> Array:
	var tile := JP.tile()
	var hw := JP.body_hw()
	var bh := JP.body_h()
	var eps := 1.0
	var x0 := 0.5 * tile
	var dx := float(off.x) * tile
	var dist := sqrt(dx * dx + float(off.y) * tile * float(off.y) * tile)
	var steps: int = max(2, int(dist / (tile * 0.25)))
	var ends := {Vector2i(0, 0): true, off: true}
	# 「支撑格」不算障碍：起点正下方那格、终点正下方那格。
	# 为什么必须排除：轨迹是按 (行,列) 直线插值的，一个"边跳边落"的长步
	# 在 t≈0 就把脚底插进了起点脚下的地面格 —— 那是玩家**站着**的地板，
	# 不是障碍。不排除的话，"任何实心格都挡人"的严格判据会把
	# **每一次下楼/落地**都判成非法（实测：连终点都不可达）。
	# 中途撞上的实心格（比如跳太高顶到天花板）仍然照算 —— 那本来就不该允许。
	ends[Vector2i(off.x, off.y + 1)] = true
	# ⚠️ 起点脚下那格**只在有横向分量时**才排除。若 off.x == 0（纯竖直下落），
	# 身体根本没离开自己那一列 —— 那就是"想穿过脚下的地板掉下去"，
	# 必须照旧判非法。漏掉这个条件时，规划器会以为"站在平台上可以直接往下钻"，
	# 于是无头机器人站在平台上、目标就在下面两格，却 900 帧原地不动（实测卡死主因）。
	if off.x != 0:
		ends[Vector2i(0, 1)] = true
	var acc := {}
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var px := x0 + dx * t
		var row := float(off.y) * t
		var feet := (row + 1.0) * tile - eps
		var top := feet - bh
		var cx_lo := int(floor((px - hw) / tile))
		var cx_hi := int(floor((px + hw) / tile))
		var cy_lo := int(floor(top / tile))
		var cy_hi := int(floor(feet / tile))
		for cx in range(cx_lo, cx_hi + 1):
			for cy in range(cy_lo, cy_hi + 1):
				var key := Vector2i(cx, cy)
				if ends.has(key):
					continue
				# 严格重叠判据
				var rx0 := float(cx) * tile
				var ry0 := float(cy) * tile
				var rx1 := rx0 + tile
				var ry1 := ry0 + tile
				if px - hw < rx1 and px + hw > rx0 and top < ry1 and feet > ry0:
					acc[key] = true
	return acc.keys()

# --------------------------------------------------------------------------
# 查询
# --------------------------------------------------------------------------

func size() -> int:
	return cells.size()

func has_offset(off: Vector2i) -> bool:
	return masks.has(off)

func allowed_dcx(dcy: int) -> PackedInt32Array:
	return by_dcy.get(dcy, PackedInt32Array())

func dcy_range() -> Vector2i:
	if cells.is_empty():
		return Vector2i.ZERO
	var lo := 1 << 30
	var hi := -(1 << 30)
	for c in cells:
		lo = mini(lo, c.y)
		hi = maxi(hi, c.y)
	return Vector2i(lo, hi)

func mask_of(off: Vector2i) -> Array:
	return masks.get(off, [])

## 缺口宽度上限：跨过 λ 格宽的缺口需要水平位移 λ+1 格，
## 且**必须双向**都允许（核服从真实物理，而物理本来就不对称）。
func gap_capacity() -> Dictionary:
	var cap := {}
	for dcy in [-1, 0, 1]:
		var allowed := {}
		for x in allowed_dcx(dcy):
			allowed[x] = true
		var k := 0
		while k + 1 <= 12 and allowed.has(k + 1) and allowed.has(-(k + 1)):
			k += 1
		cap[dcy] = maxi(1, k - 1)
	return cap

func max_crossable_barrier() -> int:
	var cap := gap_capacity()
	var m := 1 << 30
	for k in cap.keys():
		m = mini(m, int(cap[k]))
	return m

# --------------------------------------------------------------------------
# 自检：核 vs 物理（双向核对）
# --------------------------------------------------------------------------

## 正向：核里的每个偏移，在整个 (dh,dx) 区间上都必须真的可达；
## 反向：物理 + 难度旋钮全区间合格的偏移不能缺席。
func verify_against_physics() -> Array:
	var bad: Array = []
	var tile_c: int = int(Cfg.PHY["tile"])
	var tile := float(tile_c)
	var half: int = tile_c / 2
	var dh_step: int = int(Cfg.KERNEL["dh_step"])
	var d: int = int(Cfg.KERNEL["d"])
	var ref_w := 2.0 * tile
	var hmax := JP.h_max()
	var fmax := JP.fall_max()
	var co := {}
	for c in cells:
		co[c] = true

	for c in cells:
		var hit := ""
		var dh_v: int = -c.y * tile_c - half
		while dh_v <= -c.y * tile_c + half:
			var dx_v: int = c.x * tile_c - half
			while dx_v <= c.x * tile_c + half:
				if not _acceptable(dx_v, dh_v, tile, hmax, fmax):
					hit = "(dh=%d, dx=%d)" % [dh_v, dx_v]
					break
				dx_v += d
			if hit != "":
				break
			dh_v += dh_step
		if hit != "":
			bad.append("核认为可达但物理/安全判不可达: dcx=%d dcy=%d %s" % [c.x, c.y, hit])
			if bad.size() > 8:
				return bad

	var rng_max: int = mini(int(Cfg.KERNEL["forward_range"]), 8)
	for dcy in range(-4, 5):
		for dcx in range(-2, rng_max + 1):
			if dcx == 0 and dcy == 0:
				continue
			var all_ok := true
			var dh_v2: int = -dcy * tile_c - half
			while dh_v2 <= -dcy * tile_c + half:
				if float(dh_v2) > hmax or float(dh_v2) < -fmax:
					all_ok = false
					break
				var dx_v2: int = dcx * tile_c - half
				while dx_v2 <= dcx * tile_c + half:
					if not _acceptable(dx_v2, dh_v2, tile, hmax, fmax):
						all_ok = false
						break
					dx_v2 += d
				if not all_ok:
					break
				dh_v2 += dh_step
			if all_ok and not co.has(Vector2i(dcx, dcy)):
				bad.append("物理+难度旋钮全区间可达但核里缺失: dcx=%d dcy=%d" % [dcx, dcy])
	return bad

func _acceptable(dx: int, dh: int, tile: float, hmax: float, fmax: float) -> bool:
	var t := JP.t_air(float(dh))
	if t >= JP.INF:
		return false
	if float(dh) > hmax or float(dh) < -fmax:
		return false
	if absf(float(dx)) > JP.reach_limit(t, JP.vx_dash()):
		return false
	return _ref_can_jump(dh, dx, tile)

# --------------------------------------------------------------------------
# 诊断输出
# --------------------------------------------------------------------------

func stats() -> String:
	var r := dcy_range()
	return ("运动核: %d 个格子偏移, dcy ∈ [%d, %d], tile=%dpx, d=%dpx, dh_step=%dpx, 编译 %d ms"
			% [cells.size(), r.x, r.y, int(Cfg.PHY["tile"]), int(Cfg.KERNEL["d"]),
			   int(Cfg.KERNEL["dh_step"]), compiled_at_ms])

func table(dcy_from: int = -13, dcy_to: int = 6) -> String:
	var lines := ["dcy  Δh(px)  dcx 范围                 允许的 dcx"]
	for dcy in range(dcy_from, dcy_to + 1):
		var ds := allowed_dcx(dcy)
		var dh := -dcy * int(Cfg.PHY["tile"])
		var rng := "—" if ds.is_empty() else "%d..%d" % [ds[0], ds[ds.size() - 1]]
		lines.append("%4d %6d  %-22s %s" % [dcy, dh, rng, str(Array(ds))])
	return "\n".join(lines)

func gap_capacity_text() -> String:
	var cap := gap_capacity()
	var parts := []
	for k in [-1, 0, 1]:
		parts.append("dcy=%+d: 缺口<=%d 格" % [k, int(cap[k])])
	return "；".join(parts) + "；实体障碍连排上限 = %d 格" % max_crossable_barrier()
