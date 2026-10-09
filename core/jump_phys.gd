# JumpPhys —— 跳跃运动学（唯一物理真相）
#
# 全部由 Cfg.PHY 推导：h_single / h_max / t_rise / t_air / reach_x_*。
# 「上升段更久与回落段更短精确抵消」=> 每一档内滞空时间是常量，
# 因此射程是**两档阶梯**而不是连续函数。生成器必须按档取安全间距。
#
# 这份实现直接服务两件事：
#   1. 运动核编译（gen/motion_kernel.gd）—— 把物理编译成格偏移集合 K；
#   2. 单测里"核 vs 物理"的双向核对（V1 系列断言）。
#
# 纯静态函数，无状态。平台/实心块用 Dictionary 表示：
#   Platform = {x0, y0, x1, y1}
#   Solid    = {x0, y0, x1, y1}

extends RefCounted

const Cfg = preload("res://core/constants.gd")

const INF := 1e30

# --------------------------------------------------------------------------
# 派生量
# --------------------------------------------------------------------------

static func h_single() -> float:
	return Cfg.h_single()

static func h_max() -> float:
	return Cfg.h_max()

static func v0() -> float:
	return float(Cfg.PHY["v0"])

static func gravity() -> float:
	return float(Cfg.PHY["gravity"])

static func vx_dash() -> float:
	return float(Cfg.PHY["vx_dash"])

static func vx_run() -> float:
	return float(Cfg.PHY["vx_run"])

static func fall_max() -> float:
	return float(Cfg.PHY["fall_max"])

static func tile() -> float:
	return float(Cfg.PHY["tile"])

static func body_hw() -> float:
	return float(Cfg.PHY["body_hw"])

static func body_h() -> float:
	return float(Cfg.PHY["body_h"])

## 从起跳开始，首次上升到高度 dh 所需时间（上升段）。
## 单段不够时用二段跳；超出 h_max 返回 INF。
static func t_rise(dh: float) -> float:
	if dh <= 0.0:
		return 0.0
	var g := gravity()
	var v := v0()
	var disc := v * v - 2.0 * g * dh
	if disc >= 0.0:
		return (v - sqrt(disc)) / g
	if not bool(Cfg.PHY["double_jump"]):
		return INF
	var v2: float = float(Cfg.PHY["double_jump_factor"]) * v
	var t1 := v / g
	var dh2 := dh - h_single()
	var disc2 := v2 * v2 - 2.0 * g * dh2
	if disc2 < 0.0:
		return INF
	return t1 + (v2 - sqrt(disc2)) / g

## 从顶点自由下落到高度 dh 的时间。
static func t_fall_from(dh: float, apex: float = -1.0) -> float:
	var top: float = h_max() if apex < 0.0 else apex
	var drop := top - dh
	if drop <= 0.0:
		return 0.0
	return sqrt(2.0 * drop / gravity())

## 纯自由落体 dh 距离的时间。
static func t_down(dh: float) -> float:
	if dh <= 0.0:
		return 0.0
	return sqrt(2.0 * dh / gravity())

## 总滞空时间（决定水平射程）—— 这是最容易被写成「上升时间」的一条。
static func t_air(dh: float) -> float:
	if dh < 0.0:
		# 先起跳，再从本次顶点下落（不是静止自由落体！差 20 倍）
		return t_rise(0.0) + t_fall_from(dh, h_single())
	var tr := t_rise(dh)
	if tr >= INF:
		return INF
	var apex := h_single() if dh <= h_single() else h_max()
	return tr + t_fall_from(dh, apex)

## 高差 dh 时允许的最大水平间距（不可达返回 -1）。
static func reach_x_to(dh: float) -> float:
	if dh > h_max():
		return -1.0
	var t := t_air(dh)
	if t >= INF:
		return -1.0
	return vx_dash() * t

## 难度旋钮后的射程上限：|dx| <= safety * vx * t_air - landing_margin
#
# 为什么不是 |dx| <= safety*vx*t_air：那会把**近距离小跳**也剪掉，
# 于是核在 dcy=0 上变成「向左 2 格、向右 6 格」的畸形形状。
static func reach_limit(t: float, vx: float) -> float:
	return float(Cfg.KERNEL["safety"]) * vx * t - float(Cfg.KERNEL["landing_margin"])

## 生成器用的**安全间距**：留 15% 余量，避免「刚好够」导致操作容错为零。
## 注意：这是从物理**推导**出来的，不是手写魔数。生成器实际用的是运动核，
## 这个函数用于诊断与房间级验收清单 G3。
static func safe_gap(dh: float) -> float:
	var r := reach_x_to(dh)
	if r < 0.0:
		return -1.0
	return r * 0.85

# --------------------------------------------------------------------------
# 几何
# --------------------------------------------------------------------------

static func _plat_left(p: Dictionary) -> float:
	return min(float(p["x0"]), float(p["x1"]))

static func _plat_right(p: Dictionary) -> float:
	return max(float(p["x0"]), float(p["x1"]))

static func _plat_top(p: Dictionary) -> float:
	return min(float(p["y0"]), float(p["y1"]))

static func _plat_cx(p: Dictionary) -> float:
	return (_plat_left(p) + _plat_right(p)) * 0.5

static func is_blocked_at(solids: Array, x: float, y: float) -> bool:
	for s in solids:
		if x >= float(s["x0"]) and x <= float(s["x1"]) \
				and y >= float(s["y0"]) and y <= float(s["y1"]):
			return true
	return false

static func _overlaps_x(s: Dictionary, xa: float, xb: float) -> bool:
	var lo: float = min(xa, xb)
	var hi: float = max(xa, xb)
	return not (hi < float(s["x0"]) or lo > float(s["x1"]))

## 起跳点正上方 rise 距离内是否有天花板。按角色半宽扫掠（不是单点探测）。
static func _rise_clear(solids: Array, x: float, from_y: float, dh: float) -> bool:
	var top: float = from_y - maxf(0.0, dh)
	var hw := body_hw()
	for s in solids:
		if _overlaps_x(s, x - hw, x + hw) and float(s["y1"]) >= top and float(s["y0"]) <= from_y:
			return true
	return false

## 在高度 y 上从 xa 平移到 xb 是否畅通。
static func _path_horizontally_clear(solids: Array, xa: float, xb: float, y: float) -> bool:
	var lo: float = min(xa, xb)
	var hi: float = max(xa, xb)
	for s in solids:
		if _overlaps_x(s, lo, hi) and float(s["y0"]) <= y and y <= float(s["y1"]):
			return false
	return true

## 沿抛物线扫掠检查是否撞到实心块。
static func _arc_clear(solids: Array, x_from: float, y_from: float,
					   x_to: float, y_to: float, apex_y: float, steps: int = 24) -> bool:
	if abs(x_to - x_from) < 1e-9:
		steps = 2
	var apex_x := (x_from + x_to) * 0.5
	var a := 0.0
	if abs(apex_x - x_to) >= 1e-9 and abs(apex_x - x_from) >= 1e-9:
		a = (y_to - apex_y) / ((x_to - apex_x) * (x_to - apex_x))
	for i in range(steps + 1):
		var f := float(i) / float(steps)
		var x := x_from + (x_to - x_from) * f
		var y := apex_y + a * (x - apex_x) * (x - apex_x)
		if is_blocked_at(solids, x, y):
			return false
		if is_blocked_at(solids, x, y + body_h()):
			return false
	return true

# --------------------------------------------------------------------------
# 主判定
# --------------------------------------------------------------------------

## 能否从 src 平台起跳落到 dst 平台。
## 采样 3x3=9 组合，只要存在一对成功即判可达（与原型 jumpcore.can_jump 同构）。
static func can_jump(src: Dictionary, dst: Dictionary, solids: Array = [],
					 sample: int = 9) -> Dictionary:
	if src == dst:
		return {"ok": false, "reason": "same-platform"}
	var src_top := _plat_top(src)
	var dst_top := _plat_top(dst)
	var src_l := _plat_left(src)
	var src_r := _plat_right(src)
	var dst_l := _plat_left(dst)
	var dst_r := _plat_right(dst)

	# 平坦连接：同高且水平重叠 -> 走过去即可
	if abs(src_top - dst_top) < 1.0:
		if not (src_r < dst_l or dst_r < src_l):
			return {"ok": true, "reason": "walk", "dh": 0.0, "t": 0.0}
		var gap: float = max(src_l, dst_l) - min(src_r, dst_r)
		if gap <= max(1.0, tile() * 0.5):
			var xa: float = src_r if src_l < dst_l else src_l
			var xb: float = dst_l if src_l < dst_l else dst_r
			if _path_horizontally_clear(solids, xa, xb, src_top):
				return {"ok": true, "reason": "walk-step", "dh": 0.0, "t": 0.0}

	var vx := vx_dash()
	var hmax := h_max()
	var hs := h_single()

	var xs_src: Array = []
	var xs_dst: Array = []
	if sample <= 1:
		xs_src = [_plat_cx(src)]
		xs_dst = [_plat_cx(dst)]
	else:
		for i in range(sample):
			xs_src.append(src_l + (src_r - src_l) * float(i) / float(sample - 1))
			xs_dst.append(dst_l + (dst_r - dst_l) * float(i) / float(sample - 1))

	var best_fail := "no-feasible-arc"
	for px in xs_src:
		for qx in xs_dst:
			var dh_up: float = src_top - dst_top
			if dh_up > hmax:
				best_fail = "too-high"
				continue
			var dist: float = abs(qx - px)
			var t := t_air(dh_up)
			if t >= INF:
				best_fail = "t_air-inf"
				continue
			var max_dx := vx * t
			if dist > max_dx + 1e-6:
				best_fail = "too-far"
				continue
			var rise_to: float = min(max(0.0, dh_up), hmax)
			if _rise_clear(solids, px, src_top, rise_to):
				best_fail = "ceiling-blocks-rise"
				continue
			if is_blocked_at(solids, qx, dst_top - 1.0):
				best_fail = "landing-blocked"
				continue
			var apex_y: float = src_top - (hmax if dh_up > hs else hs)
			if not _arc_clear(solids, px, src_top, qx, dst_top, apex_y):
				best_fail = "arc-blocked"
				continue
			return {"ok": true, "reason": "jump", "dh": dh_up, "t": t}
	return {"ok": false, "reason": best_fail}

# --------------------------------------------------------------------------
# 诊断
# --------------------------------------------------------------------------

static func summary() -> String:
	return ("v0=%.0f g=%.0f vx_run=%.0f vx_dash=%.0f double=%s x%.1f | "
			+ "h_single=%.1fpx h_max=%.1fpx | t_air(flat)=%.3fs | "
			+ "reach flat=%.1fpx up@hs=%.1fpx up@hmax=%.1fpx down=%.1fpx") % [
		v0(), gravity(), vx_run(), vx_dash(),
		str(Cfg.PHY["double_jump"]), float(Cfg.PHY["double_jump_factor"]),
		h_single(), h_max(), t_air(0.0),
		reach_x_to(0.0), reach_x_to(h_single()), reach_x_to(h_max() * 0.999),
		reach_x_to(-fall_max()),
	]
