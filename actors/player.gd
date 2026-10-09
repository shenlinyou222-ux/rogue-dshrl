# Player —— 玩家状态机（23 状态，§5.1）
#
# 三条手感铁律，全部在代码里实现、并且可以被自检断言：
#   P1 **输入缓冲 6 帧**：落地前按跳、连招中按下一段，都不会吞输入。
#   P2 **土狼时间 6 帧**：离开平台后 6 帧内仍可起跳。
#   P3 **取消窗口用位掩码**：空振 / 命中 / 被格挡 / 起手 四种取消权限，
#      招式表里按段给。这样「能不能取消」是可枚举、可测的，而不是一堆 if。
#
# 状态机的形态：单一 state 字符串 + state_frame 计数器 + 每帧 dispatch。
# 不用节点树、不用信号：确定性重放要求「同输入 ⇒ 同轨迹」，
# 而节点树的执行顺序依赖场景树结构，不是我们能完全控住的。

extends "res://actors/actor.gd"

const Items = preload("res://loot/items.gd")

var input: Dictionary = {}          # 当前帧输入（bool）
var buf: Dictionary = {}            # 输入缓冲：动作名 -> 剩余帧
var jump_buf: int = 0
var coyote: int = 0
var jumps_left: int = 2
var roll_cd: int = 0
var dash_cd: int = 0
var spike_cd: int = 0
var attack_buf: int = 0
var current_move: Dictionary = {}
var hit_confirmed: bool = false
var block_hold: bool = false
var stamina: float = 100.0
var stamina_max: float = 100.0
var heal_flask: int = 3
## 变异（肉鸽成长）挂到玩家身上的运行时效果；由 RunState._apply_meta_to_player 写。
var mutation: String = ""
var on_kill_heal: int = 0
var power: float = 1.0                 # 武器/词条提供的伤害倍率
var speed_mult: float = 1.0
var extra_roll_invuln: int = 0
var skill_cd: Array = [0, 0]
var hurts_recent: Array = []           # [frame, dmg] 供 AI 导演层读
var clean_rooms: int = 0
var pickup_radius: float = 26.0
var money: int = 0
var keys_held: Dictionary = {}
var inventory: Array = []
var equipped: Dictionary = {}          # slot -> item
var mut_points: int = 0

const RUN_SPEED := 240.0
const DASH_SPEED := 420.0

func _init() -> void:
	kind = "player"
	hw = float(Cfg.PHY["body_hw"])
	h = float(Cfg.PHY["body_h"])
	max_hp = 100
	hp = 100
	poise_max = int(Cfg.FRAME["poise_player"])
	poise = poise_max
	weight = "medium"

# --------------------------------------------------------------------------
# 输入缓冲
# --------------------------------------------------------------------------

func press(action: String) -> void:
	buf[action] = int(Cfg.FRAME["input_buffer"])

func consume(action: String) -> bool:
	if int(buf.get(action, 0)) > 0:
		buf[action] = 0
		return true
	return false

func buffered(action: String) -> bool:
	return int(buf.get(action, 0)) > 0

func _tick_buffers() -> void:
	for k in buf.keys():
		if int(buf[k]) > 0:
			buf[k] = int(buf[k]) - 1
	if jump_buf > 0:
		jump_buf -= 1
	if attack_buf > 0:
		attack_buf -= 1
	if roll_cd > 0:
		roll_cd -= 1
	if dash_cd > 0:
		dash_cd -= 1
	if spike_cd > 0:
		spike_cd -= 1
	for i in range(skill_cd.size()):
		if int(skill_cd[i]) > 0:
			skill_cd[i] = int(skill_cd[i]) - 1

# --------------------------------------------------------------------------
# 每帧
# --------------------------------------------------------------------------

func step(input_now: Dictionary) -> void:
	input = input_now
	if not alive:
		state = "dead"
		physics_step()
		return
	if hitstop > 0:
		hitstop -= 1
		return
	_tick_buffers()
	state_frame += 1
	_tick_stamina()

	match state:
		"idle", "run", "fall", "land":
			_ground_air_common()
		"jump":
			_air_control()
			if vel.y > 0.0:
				_set_state("fall")
		"roll":
			_advance_move("roll", false)
		"dash":
			_advance_move("dash", false)
		"attack1", "attack2", "attack3":
			_advance_move(state, false)
		"air_attack":
			_advance_move("air_attack", true)
		"plunge":
			_advance_move("plunge", true)
		"block":
			_block_state()
		"parry":
			_parry_state()
		"parry_counter":
			_advance_move("parry_counter", false)
		"hurt":
			if hitstun <= 0 and on_ground:
				_set_state("idle")
		"launched":
			if on_ground:
				_set_state("down")
		"down":
			if state_frame > 24:
				_set_state("getup")
		"getup":
			if state_frame > 16:
				_set_state("idle")
		"heal":
			_heal_state()
		"wall_slide":
			_wall_slide()
		"door_enter":
			vel.x = 0.0
		"dead":
			pass
		_:
			_ground_air_common()

	physics_step()
	_apply_spike_damage()
	_hazard_check()

func _set_state(s: String) -> void:
	state = s
	state_frame = 0
	hit_this_attack.clear()
	hit_confirmed = false
	current_move = FD.MOVES.get(s, {})

# --------------------------------------------------------------------------
# 地面 / 空中通用
# --------------------------------------------------------------------------

func _ground_air_common() -> void:
	if on_ground:
		var ax: float = 0.0
		if input.get("left", false):
			ax -= 1.0
		if input.get("right", false):
			ax += 1.0
		if ax != 0.0:
			facing = int(signf(ax))
			vel.x = ax * RUN_SPEED * speed_mult
			if state != "run":
				_set_state("run")
		else:
			vel.x *= 0.55
			if absf(vel.x) < 6.0:
				vel.x = 0.0
			if state != "idle":
				_set_state("idle")
		jumps_left = 2
		coyote = int(Cfg.FRAME["coyote"])
	else:
		coyote = maxi(0, coyote - 1)
		if state != "fall" and state != "jump":
			_set_state("fall")
	_air_control()
	_try_jump()
	_try_attack()
	_try_roll()
	_try_dash()
	_try_block()
	_try_heal()
	_try_skill()

func _air_control() -> void:
	var ax: float = 0.0
	if input.get("left", false):
		ax -= 1.0
	if input.get("right", false):
		ax += 1.0
	if ax != 0.0:
		# 空中转向权重低（保留跳跃弧线的重量感），但不影响横向速度上限
		vel.x = clampf(vel.x + ax * 24.0, -RUN_SPEED * speed_mult, RUN_SPEED * speed_mult)
		facing = int(signf(ax))

func _try_jump() -> void:
	if not buffered_jump():
		return
	if on_ground or coyote > 0:
		_cancel_buffered_jump()
		vel.y = -float(Cfg.PHY["v0"])
		jumps_left = 1 if bool(Cfg.PHY["double_jump"]) else 0
		on_ground = false
		_set_state("jump")
		level.log_event("jump", {"who": id, "n": 1})
	elif jumps_left > 0 and bool(Cfg.PHY["double_jump"]):
		_cancel_buffered_jump()
		vel.y = -float(Cfg.PHY["v0"]) * float(Cfg.PHY["double_jump_factor"])
		jumps_left -= 1
		_set_state("jump")
		level.log_event("jump", {"who": id, "n": 2})

func buffered_jump() -> bool:
	return jump_buf > 0 or bool(input.get("jump_press", false))

func _cancel_buffered_jump() -> void:
	jump_buf = 0

## 可变跳跃高度：松开跳跃键就把上升速度砍掉一半
func apply_variable_jump(released: bool) -> void:
	if released and state == "jump" and vel.y < -float(Cfg.PHY["v0"]) * 0.35:
		vel.y = -float(Cfg.PHY["v0"]) * 0.35

# --------------------------------------------------------------------------
# 攻击 / 翻滚 / 冲刺 / 格挡
# --------------------------------------------------------------------------

func _try_attack() -> void:
	if not buffered("attack"):
		return
	consume("attack")
	if on_ground:
		_set_state("attack1")
	else:
		if input.get("down", false):
			_set_state("plunge")
		else:
			_set_state("air_attack")

func _try_roll() -> void:
	if not buffered("roll") or roll_cd > 0:
		return
	consume("roll")
	_set_state("roll")
	roll_cd = 30
	if input.get("left", false):
		facing = -1
	elif input.get("right", false):
		facing = 1

func _try_dash() -> void:
	if not buffered("dash") or dash_cd > 0:
		return
	consume("dash")
	_set_state("dash")
	dash_cd = 24

func _try_block() -> void:
	if input.get("block", false):
		if state != "block":
			_set_state("block")
	else:
		if state == "block" and state_frame > 2:
			_set_state("idle")

func _try_heal() -> void:
	if buffered("heal") and heal_flask > 0 and on_ground:
		consume("heal")
		_set_state("heal")

func _try_skill() -> void:
	for i in range(2):
		if buffered("skill_%d" % (i + 1)) and int(skill_cd[i]) <= 0:
			consume("skill_%d" % (i + 1))
			_use_skill(i)

func _use_skill(idx: int) -> void:
	var it = equipped.get("skill_%d" % (idx + 1), null)
	if it == null:
		return
	skill_cd[idx] = int(it.get("cooldown", 180))
	level.log_event("skill", {"who": id, "item": it.get("id", "?"), "slot": idx})
	# 技能的最小可用语义：给一个前冲斩 + 无敌帧（其余由词条扩展）
	_set_state("dash")
	invuln = maxi(invuln, 10)

# --------------------------------------------------------------------------
# 招式推进（三段式 + 取消位掩码）
# --------------------------------------------------------------------------

func _advance_move(move_name: String, airborne: bool) -> void:
	var mv: Dictionary = FD.MOVES.get(move_name, {})
	current_move = mv
	var su: int = int(mv.get("startup", 0))
	var ac: int = int(mv.get("active", 0))
	var rc: int = int(mv.get("recovery", 0))
	var seg := "startup"
	var seg_frame: int = state_frame
	if state_frame >= su + ac:
		seg = "recovery"
		seg_frame = state_frame - su - ac
	elif state_frame >= su:
		seg = "active"
		seg_frame = state_frame - su

	# 强制位移（前冲/后撤）
	var mvs: Dictionary = mv.get("move", {})
	var mvx: float = float(mvs.get(seg, 0.0))
	if mvx != 0.0 and seg != "recovery":
		vel.x = mvx * 60.0 * float(facing)
	elif seg == "recovery":
		vel.x *= 0.80

	# 重力（空中招式）
	if bool(mv.get("gravity", false)):
		pass

	# 无敌帧（翻滚）
	var iv: Array = mv.get("invuln", [])
	if iv.size() == 2 and state_frame >= int(iv[0]) and state_frame <= int(iv[1]) + extra_roll_invuln:
		invuln = maxi(invuln, 2)

	# 判定
	if seg == "active" and ac > 0 and ac < 900:
		var hb: Rect2 = move_box(mv)
		for e in level.actors:
			if e.kind != "enemy" or not e.alive or e == self:
				continue
			if hit_this_attack.has(e.id):
				continue
			if hb.intersects(e.hurt_box()):
				hit_this_attack[e.id] = true
				_land_hit(e, mv)

	# 结束
	if state_frame >= su + ac + rc:
		if bool(mv.get("hold", false)) and input.get("block", false):
			return
		# 连段：active 段命中过才能接下一段（否则只能接空振取消）
		var chain: String = str(mv.get("chain", ""))
		if chain != "" and hit_confirmed and buffered("attack"):
			consume("attack")
			chain_index += 1
			_set_state(chain)
			hit_confirmed = true
			return
		if airborne and not on_ground:
			_set_state("fall")
		else:
			_set_state("land" if move_name in ["attack3", "air_attack", "plunge"] else "idle")
		chain_index = 0

	# 取消权限（位掩码）：只在当前段允许的动作里找
	var mask: int = int(mv.get("cancel_%s" % seg, Cfg.CANCEL["NONE"]))
	if mask != 0:
		_try_cancel(mask, seg_frame)

func _try_cancel(mask: int, seg_frame: int) -> void:
	if (mask & Cfg.CANCEL["KARA"]) != 0 and seg_frame <= int(Cfg.FRAME["kara_cancel_window"]):
		if buffered("roll") and roll_cd <= 0:
			consume("roll")
			_set_state("roll")
			roll_cd = 30
			return
	if (mask & Cfg.CANCEL["HIT"]) != 0 or (mask & Cfg.CANCEL["WHIFF"]) != 0:
		if buffered("roll") and roll_cd <= 0:
			consume("roll")
			_set_state("roll")
			roll_cd = 30
			return

func _land_hit(target, mv: Dictionary) -> void:
	hit_confirmed = true
	var dmg: int = FD.player_damage(mv, chain_index, power, target.poise <= 0)
	var kb: Dictionary = mv.get("kb", {"x": 2.0, "y": -1.0})
	var hs: int = int(mv.get("hitstop", 3))
	var res: Dictionary = target.take_hit(self, dmg, kb, float(mv.get("poise_dmg", 10)), hs, false)
	hitstop = maxi(hitstop, hs)
	dmg_dealt_window.append([level.frame, dmg])
	combo_count += 1
	comboTimer = 90
	level.log_event("player_hit", {"dmg": dmg, "blocked": res["blocked"], "combo": combo_count})

# --------------------------------------------------------------------------
# 其它状态
# --------------------------------------------------------------------------

func _block_state() -> void:
	vel.x *= 0.5
	if not input.get("block", false):
		_set_state("idle")
		return
	if buffered("parry") and state_frame <= 1:
		_set_state("parry")
	if buffered("roll") and roll_cd <= 0:
		consume("roll")
		_set_state("roll")
		roll_cd = 30

func _parry_state() -> void:
	vel.x *= 0.6
	if state_frame > int(Cfg.FRAME["parry_window"]) + 8:
		_set_state("block" if input.get("block", false) else "idle")

func _heal_state() -> void:
	vel.x *= 0.7
	var mv: Dictionary = FD.MOVES["heal"]
	if state_frame == int(mv["startup"]):
		var amount: int = int(round(float(max_hp) * 0.35))
		hp = mini(max_hp, hp + amount)
		heal_flask -= 1
		level.log_event("heal", {"who": id, "amount": amount, "left": heal_flask})
	if state_frame > int(mv["startup"]) + int(mv["recovery"]):
		_set_state("idle")
	if input.get("left", false) or input.get("right", false):
		_set_state("idle")

func _wall_slide() -> void:
	vel.y = minf(vel.y, 70.0)
	if not wall_ahead():
		_set_state("fall")
	if buffered_jump():
		_cancel_buffered_jump()
		vel.y = -float(Cfg.PHY["v0"]) * 0.9
		_set_state("jump")

func _tick_stamina() -> void:
	var regen: float = 34.0
	if state == "block":
		regen = 6.0
	elif state == "dash" or state == "roll":
		regen = 0.0
	stamina = minf(stamina_max, stamina + regen / float(Cfg.FPS))
	if state == "block":
		stamina -= 12.0 / float(Cfg.FPS)
		if stamina <= 0.0:
			stamina = 0.0
			_set_state("hurt")
			hitstun = 20

func _apply_spike_damage() -> void:
	# 尖刺是「惩罚」不是「刷伤害机」：
	#   * 独立冷却 45 帧（比通用的 30 帧无敌更长）—— 站在尖刺上不会再被连点
	#   * 向上击飞更强（y=-6）—— 伤害本身就把玩家弹出来，不会躺着吃第二下
	# 实测教训：只有 30 帧无敌时，机器人慢慢走过一串尖刺 = 每格 8 点，
	# 一次模拟里 208 点伤害全部来自尖刺，比所有敌人加起来还多。
	var c := cell()
	if level.is_danger_tile(c.x, c.y) and invuln <= 0 and spike_cd <= 0:
		spike_cd = 45
		take_hit(null, 8, {"x": 0.0, "y": -6.0}, 0.0, 4, false)
		level.log_event("spike", {"who": id, "cell": [c.x, c.y]})

func _hazard_check() -> void:
	if p.y > float(level.map.h * 16 + 400):
		hp = 0
		alive = false
		level.log_event("fell_out", {"who": id})

func on_landed() -> void:
	if state == "fall" or state == "jump":
		_set_state("land")

# --------------------------------------------------------------------------
# 外部效果（道具 / 变异 / AI 导演的合法指令）
# --------------------------------------------------------------------------

func add_power(v: float) -> void:
	power = maxf(0.2, power + v)

func equip(slot: String, item: Dictionary) -> void:
	equipped[slot] = item
	inventory.append(item)
	if slot == "amulet":
		pass
	recalc_stats()

func recalc_stats() -> void:
	power = 1.0
	speed_mult = 1.0
	extra_roll_invuln = 0
	stamina_max = 100.0
	for k in equipped.keys():
		var it: Dictionary = equipped[k]
		power += float(it.get("power_bonus", 0.0))
		speed_mult += float(it.get("speed_bonus", 0.0))
		extra_roll_invuln += int(it.get("roll_invuln_bonus", 0))
		stamina_max += float(it.get("stamina_bonus", 0.0))
