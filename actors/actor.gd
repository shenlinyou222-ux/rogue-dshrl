# Actor —— 所有活动体的基类（玩家 / 敌人 / 投射物）
#
# 物理用的是**和运动核 K 完全相同的连续模型**（同一个 v0/g），这点很关键：
# 核 K 是用连续方程推出的「可达性证明」，运行时如果换成另一套离散化
# （比如定点 1/256 px 累加），两边的误差会去吃掉 KERNEL.safety 留的那点余量，
# 于是「证明能跳过去的地方实际跳不过去」。
#   ⇒ 运行时物理 = 连续方程 + 60 Hz 定步长；随机性 = 整数 RNG（跨进程一致）。
# 复现性因此分两层：**世界线（生成）跨机器逐位一致；模拟（战斗）同构同版本一致**。
#
# 碰撞：AABB 对格子，X/Y 分轴推进 + 4px 子步（防止穿过 1 格宽的缝）。

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const FD = preload("res://combat/framedata.gd")

const TILE := 16.0
const SUBSTEP := 4.0

var level = null
var id: int = 0
var kind: String = "actor"          # player / enemy / projectile
var p: Vector2 = Vector2.ZERO       # 脚底中心
var vel: Vector2 = Vector2.ZERO
var hw: float = 6.0                 # 半宽
var h: float = 28.0                 # 身高
var facing: int = -1
var on_ground: bool = false
var alive: bool = true

var hp: int = 10
var max_hp: int = 10
var poise: int = 20
var poise_max: int = 20
var weight: String = "light"
var super_armor: bool = false

var invuln: int = 0
var hitstun: int = 0
var hitstop: int = 0
var flash: int = 0
var kb_timer: int = 0
var guard_active: bool = false       # 敌人正面格挡（由 Enemy 每帧维护）

var state: String = "idle"
var state_frame: int = 0
var chain_index: int = 0
var last_hit_by = null
var hit_this_attack: Dictionary = {}
var combo_count: int = 0
var comboTimer: int = 0

# 统计（AI 导演层读这些；只读，模型不能改）
var dmg_dealt_window: Array = []    # [frame, amount]
var dmg_taken_window: Array = []
var whiff_count: int = 0
var last_ground_frame: int = 0

func setup(p_level, p_kind: String, x: float, y: float) -> void:
	level = p_level
	kind = p_kind
	p = Vector2(x, y)

func body_rect() -> Rect2:
	return Rect2(p.x - hw, p.y - h, hw * 2.0, h)

func center() -> Vector2:
	return Vector2(p.x, p.y - h * 0.5)

# --------------------------------------------------------------------------
# 碰撞
# --------------------------------------------------------------------------

func _blocked_rect(cx0: int, cy0: int, cx1: int, cy1: int) -> bool:
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			if level.is_blocked_tile(cx, cy):
				return true
	return false

func collides() -> bool:
	# 半开区间约定：矩形**含**自己的上/左边，**不含**下/右边。
	# 少了这个 -0.01：身体右缘正好落在格边界上时会被判成"压在右格上"，
	# 而右格若是实心，角色就**永久嵌进地形**：两个方向都推不动（实测
	# "vx=-240 全速跑、x 三个采样点一模一样"），向下的吸附还会把它往上顶 16px
	# 并置 on_ground=true —— 这就是历史上"站在半空里"的真相。
	var x0 := int(floor((p.x - hw) / TILE))
	var x1 := int(floor((p.x + hw - 0.01) / TILE))
	var y0 := int(floor((p.y - h) / TILE))
	var y1 := int(floor((p.y - 0.01) / TILE))
	return _blocked_rect(x0, y0, x1, y1)

## 分轴推进 + 子步。返回是否发生了碰撞。
##
## ⚠️ 吸附（snap）必须"吸附后仍然不重叠"才算数 —— 见 _snap_x / _snap_y 的注释，
##    这是本项目最隐蔽的一个 bug：向上碰撞时把玩家往下推 16px，
##    玩家一旦有一个像素卡进地形，就会被这个吸附一步步"吸"穿整个地图，
##    最后从世界底部掉出去（实测 fell_out，2.3 秒就死）。
func move_x(dx: float) -> bool:
	if absf(dx) < 0.0001:
		return false
	var remaining: float = dx
	while absf(remaining) > 0.0001:
		var s: float = clampf(remaining, -SUBSTEP, SUBSTEP)
		p.x += s
		remaining -= s
		if collides():
			p.x -= s
			_snap_x(s)
			return true
	return false

func move_y(dy: float) -> bool:
	if absf(dy) < 0.0001:
		return false
	var remaining: float = dy
	while absf(remaining) > 0.0001:
		var s: float = clampf(remaining, -SUBSTEP, SUBSTEP)
		p.y += s
		remaining -= s
		if collides():
			p.y -= s
			_snap_y(s)
			return true
	return false

## 贴到阻挡格的边；若吸附后的位置仍然重叠，就退回移动前的位置（保证"永不进墙"）。
func _snap_x(s: float) -> void:
	var keep := p.x
	if s > 0.0:
		p.x = float(int(floor((p.x + s + hw) / TILE)) + 1) * TILE - hw - 0.01
	else:
		p.x = float(int(floor((p.x + s - hw) / TILE))) * TILE + hw + 0.01
	if collides():
		p.x = keep

func _snap_y(s: float) -> void:
	var keep := p.y
	if s > 0.0:
		# 向下：脚底停在"将要踏入的那一行"的顶面
		p.y = float(int(floor((p.y + s - 0.01) / TILE))) * TILE - 0.01
		if collides():
			p.y = keep
		on_ground = true
	else:
		# 向上：头顶停在"头顶所在行"的下面一格。注意这里必须按头顶所在行算，
		# 而且吸附后要复检 —— 否则会把角色按进地板里。
		p.y = float(int(floor((p.y + s - h) / TILE)) + 1) * TILE + h + 0.01
		if collides():
			p.y = keep

func ground_below() -> bool:
	var cx0 := int(floor((p.x - hw) / TILE))
	var cx1 := int(floor((p.x + hw) / TILE))
	var cy := int(floor((p.y + 0.6) / TILE))
	for cx in range(cx0, cx1 + 1):
		if level.is_blocked_tile(cx, cy):
			return true
	return false

## 前方是否有墙（用来看「贴墙」）
func wall_ahead() -> bool:
	var cx := int(floor((p.x + float(facing) * (hw + 1.0)) / TILE))
	var y0 := int(floor((p.y - h) / TILE))
	var y1 := int(floor((p.y - 0.01) / TILE))
	for cy in range(y0, y1 + 1):
		if level.is_blocked_tile(cx, cy):
			return true
	return false

func foot_row() -> int:
	return int(floor((p.y - 0.01) / TILE))

func cell() -> Vector2i:
	return Vector2i(int(floor(p.x / TILE)), foot_row())

# --------------------------------------------------------------------------
# 标准步进：重力 + 位移 + 状态计时
# --------------------------------------------------------------------------

func physics_step(gravity_on: bool = true) -> void:
	if hitstop > 0:
		hitstop -= 1
		return
	if hitstun > 0:
		hitstun -= 1
	if invuln > 0:
		invuln -= 1
	if flash > 0:
		flash -= 1
	if comboTimer > 0:
		comboTimer -= 1
		if comboTimer == 0:
			combo_count = 0
	if gravity_on:
		vel.y += float(Cfg.PHY["gravity"]) / float(Cfg.FPS)
		if vel.y > float(Cfg.PHY["fall_max"]):
			vel.y = float(Cfg.PHY["fall_max"])
	var blocked_x := move_x(vel.x / float(Cfg.FPS))
	if blocked_x:
		vel.x = 0.0
	var was_ground := on_ground
	on_ground = false
	var blocked_y := move_y(vel.y / float(Cfg.FPS))
	if not blocked_y:
		on_ground = ground_below()
	if on_ground:
		last_ground_frame = level.frame
		if vel.y > 0.0:
			vel.y = 0.0
		if not was_ground:
			on_landed()
	# 击退衰减
	if kb_timer > 0:
		kb_timer -= 1
		vel.x *= 0.86
		if kb_timer == 0:
			vel.x = 0.0

func on_landed() -> void:
	pass

# --------------------------------------------------------------------------
# 伤害结算（顺序铁律，不可换序）
# --------------------------------------------------------------------------

## 返回 Dictionary：{applied, blocked, parried, killed, dmg}
func take_hit(src, dmg: int, kb: Dictionary, poise_dmg: float, hitstop: int,
			  heavy: bool) -> Dictionary:
	# 1) 判定已在调用方完成；这里从「无敌 / 格挡检查」开始
	var res := {"applied": false, "blocked": false, "parried": false,
				"killed": false, "dmg": 0}
	if not alive or invuln > 0:
		return res

	# 2) 无敌 / 格挡 / 弹反
	var dir_ok := true
	if src != null:
		dir_ok = (src.p.x - p.x) * float(facing) > 0.0 or absf(src.p.x - p.x) < 4.0
	if kind == "player" and state == "parry" and state_frame <= int(Cfg.FRAME["parry_window"]) and dir_ok:
		res["parried"] = true
		invuln = int(Cfg.FRAME["parry_counter_stun"])
		hitstop = int(Cfg.DMG["hitstop_parry"])
		level.log_event("parry", {"who": id, "src": src.id if src != null else -1})
		return res
	var guarding: bool = false
	if kind == "player":
		guarding = (state == "block" or (state == "parry" and state_frame > int(Cfg.FRAME["parry_window"]))) and dir_ok
	else:
		# 盾兵的正面格挡：由 Enemy 每帧维护 guard_active（朝向 + 状态决定）
		guarding = guard_active and dir_ok
	if guarding:
		var reduced: int = maxi(1, int(round(float(dmg) * float(Cfg.FRAME["block_damage_mult"]))))
		hp -= reduced
		res["blocked"] = true
		res["dmg"] = reduced
		res["applied"] = true
		flash = int(Cfg.DMG["flash_frames"])
		hitstop = maxi(hitstop, 2)
		poise_dmg *= 2.0
		level.log_event("block", {"who": id, "dmg": reduced})

	# 3) 韧性
	var broke := false
	if not res["blocked"]:
		if super_armor and state_frame < 8 and kind != "player":
			poise_dmg *= 0.35
		poise -= int(round(poise_dmg))
		if poise <= 0:
			poise = 0
			broke = true
			poise = poise_max

	# 4) 伤害
	if not res["blocked"]:
		hp -= dmg
		res["dmg"] = dmg
		res["applied"] = true
		flash = int(Cfg.DMG["flash_frames"])
		dmg_taken_window.append([level.frame, dmg])

	# 5) hitstop（玩家命中时双方都顿，这是手感的来源）
	hitstop = maxi(hitstop, 1)
	if src != null and src.has_method("get") and hitstop > 0:
		src.hitstop = maxi(int(src.hitstop), hitstop)

	# 6) 击退（方向：从攻击者指向自己；没有攻击者时按自己的朝向反推）
	if not res["blocked"] or broke:
		var ks: float = FD.knockback_scale(weight)
		var dir: float = -float(facing)
		if src != null:
			dir = signf(p.x - src.p.x)
			if dir == 0.0:
				dir = -float(facing)
		vel.x = absf(float(kb.get("x", 0.0))) * 60.0 * ks * dir
		vel.y = float(kb.get("y", 0.0)) * 60.0 * ks
		kb_timer = 8
		on_ground = false
		hitstun = int(Cfg.FRAME["hitstun_heavy"] if heavy else Cfg.FRAME["hitstun_light"])
		if kind == "player":
			invuln = int(Cfg.FRAME["hurt_invuln"])
			state = "hurt"
			state_frame = 0
		else:
			if broke or heavy:
				state = "stagger"
				state_frame = 0
	elif res["blocked"]:
		poise -= int(round(poise_dmg * 0.5))
		if poise <= 0:
			poise = poise_max
			if kind == "player":
				state = "hurt"
				state_frame = 0
				hitstun = int(Cfg.FRAME["guard_crush_stun"])
				level.log_event("guard_crush", {"who": id})

	# 7) 事件日志
	if hp <= 0:
		hp = 0
		alive = false
		res["killed"] = true
		level.log_event("kill", {"who": id, "kind": kind, "by": src.id if src != null else -1})
	else:
		level.log_event("hit", {"who": id, "dmg": dmg, "blocked": res["blocked"]})
	return res

# --------------------------------------------------------------------------
# 判定位 / 受击位
# --------------------------------------------------------------------------

## 把帧数据里的 box（相对脚底中心、x 向前为正）转成世界 AABB。
func move_box(move: Dictionary) -> Rect2:
	var b: Dictionary = move["box"]
	var ox: float = float(b["ox"]) * float(facing)
	var cx: float = p.x + ox
	# oy 是**盒子中心**相对脚底的高度（负数=在上方）
	var cy: float = p.y + float(b["oy"])
	var w: float = float(b["w"])
	var hh: float = float(b["h"])
	return Rect2(cx - w * 0.5, cy - hh * 0.5, w, hh)

func hurt_box() -> Rect2:
	return body_rect().grow(-1.0)
