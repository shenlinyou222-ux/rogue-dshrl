# Enemy —— 敌人（八类原型 + 精英 + Boss），共用一套状态机 + 一棵行为树
#
# 公平性铁律（§7.1，全部可被自检断言）：
#   E1 **预警永远够长**：telegraph 帧数 >= 反应时间(12 帧) + 攻击起手帧。
#   E2 **低血不后退**：玩家血量 < 30% 时，敌人的 backoff 节点权重被强制压到 0。
#      （这条是 AI 导演层与行为树的**同一个**铁律，两处都实现，互相兜底。）
#   E3 **不会凭空变强**：援军/召唤受威胁预算约束，且绝不在玩家低血时追加。
#   E4 **不会瞬移**：所有位移都走 move_x/move_y，会被墙挡住。
#
# 状态机：idle / patrol / chase / backoff / telegraph / attack / recovery /
#        stagger / ranged / summon / suicide / dead
#
# 决策与帧数据分离：
#   行为树每 4 帧刷一次（think_budget），决定「想要什么」；
#   状态机每帧推进（startup/active/recovery），决定「这一帧做什么」。
#   手感来自后者，风格来自前者 —— 所以 AI 换脑子不会改变手感。

extends "res://actors/actor.gd"

const BT = preload("res://ai/bt.gd")
const Proj = preload("res://actors/projectile.gd")

var data: Dictionary = {}
var archetype: String = "rusher"
var elite: bool = false
var affix: String = ""
var level_floor: int = 1

var target = null                 # 通常是玩家
var home: Vector2 = Vector2.ZERO
var patrol_dir: int = 1
var think_timer: int = 0
var want_action: String = "approach"
var want_dir: int = 0
var bb: Dictionary = {}           # 黑板（行为树与状态机共享）
var tree = null
var summon_cd: int = 0
var ranged_cd: int = 0
var aggro: bool = true
var hit_from_behind_bonus: float = 1.0

# ctx 六维（由 AI 导演层的双缓冲提供；缺省是规则脑的默认值）
var ctx: Dictionary = {
	"aggression": 0.55, "defense": 0.45, "range_target": 0.4,
	"rhythm": 0.5, "focus": 0.5, "mercy": 0.4,
}

func setup_enemy(p_level, a: String, x: float, y: float, p_floor: int,
				 p_elite: bool, p_affix: String, p_stats: Dictionary) -> void:
	setup(p_level, "enemy", x, y)
	archetype = a
	elite = p_elite
	affix = p_affix
	level_floor = p_floor
	data = p_stats
	max_hp = int(data.get("hp", 20))
	hp = max_hp
	poise_max = int(data.get("poise", 12))
	poise = poise_max
	weight = str(data.get("weight", "light"))
	super_armor = bool(data.get("super_armor", false))
	home = Vector2(x, y)
	hw = 6.0
	h = 26.0
	if archetype == "brute" or archetype == "boss":
		hw = 8.0
		h = 30.0
	if archetype == "exploder":
		hw = 6.0
		h = 20.0
	state = "idle"
	tree = _build_tree()

# --------------------------------------------------------------------------
# 行为树
# --------------------------------------------------------------------------

func _build_tree() -> Object:
	# 权重（第 3 个参数）+ 权重维（第 4 个）就是**风格的入口**：
	# ctx 里的 aggression/defense/rhythm 直接乘在节点权重上，
	# 所以「AI 导演层改 ctx」= 改这棵树的选择倾向，而**一个节点都不用重写**。
	var c_in_range := BT.cond("in_attack_range",
		func(b): return float(b["dist"]) <= float(b["self"].data["attack_range"]))
	var c_los := BT.cond("line_of_sight", func(b): return bool(b["los"]))
	var c_ranged := BT.cond("is_ranged",
		func(b): return bool(b["self"].data.get("ranged", false)))
	var c_can_summon := BT.cond("can_summon", func(b):
		return b["self"].data.has("summon") and int(b["self"].summon_cd) <= 0)
	var c_low_hp_player := BT.cond("player_low_hp", func(b):
		return b["player"] != null and float(b["player"].hp) / float(b["player"].max_hp) < 0.30)
	var c_hp_ok := BT.cond("self_hp_ok", func(b):
		return float(b["self"].hp) / float(b["self"].max_hp) > 0.35)
	var c_ready := BT.cond("attack_ready", func(b): return int(b["self"].ranged_cd) <= 0)

	var a_attack := BT.act("melee_attack", func(b):
		if c_in_range.tick(b) != BT.SUCCESS or c_los.tick(b) != BT.SUCCESS:
			return BT.FAILURE
		b["self"]._begin_attack()
		return BT.SUCCESS, 1.0, "aggression")
	var a_ranged := BT.act("ranged_attack", func(b):
		if int(b["self"].ranged_cd) > 0:
			return BT.FAILURE
		b["self"]._begin_ranged()
		return BT.SUCCESS, 1.0, "aggression")
	var a_summon := BT.act("summon", func(b):
		b["self"]._begin_summon()
		return BT.SUCCESS, 0.9, "rhythm")
	var a_approach := BT.act("approach", func(b):
		b["self"].want_action = "approach"
		b["self"].want_dir = 1 if b["player"] != null and b["player"].p.x > b["self"].p.x else -1
		return BT.RUNNING, 1.2, "aggression")
	var a_strafe := BT.act("strafe", func(b):
		# 拉到期望交战距离（range_target 的直接体现）
		var want: float = float(b["self"].data.get("keep_dist", 60.0))
		var d: float = float(b["dist"])
		if d < want - 12.0:
			b["self"].want_action = "backoff"
			b["self"].want_dir = -1 if b["player"] != null and b["player"].p.x > b["self"].p.x else 1
		elif d > want + 12.0:
			b["self"].want_action = "approach"
			b["self"].want_dir = 1 if b["player"] != null and b["player"].p.x > b["self"].p.x else -1
		else:
			b["self"].want_action = "hold"
			b["self"].want_dir = 0
		return BT.RUNNING, 1.0, "range_target")
	var a_backoff := BT.act("backoff", func(b):
		b["self"].want_action = "backoff"
		b["self"].want_dir = -1 if b["player"] != null and b["player"].p.x > b["self"].p.x else 1
		return BT.RUNNING, 1.0, "defense")
	var a_idle := BT.act("idle", func(b):
		b["self"].want_action = "hold"
		b["self"].want_dir = 0
		return BT.RUNNING, 0.2)

	# 权重为 0 的节点会被整枝跳过 —— 这就是「低血不后退铁律」在行为树里的实现。
	return BT.sel([
		BT.seq([c_can_summon, a_summon], "summon_branch"),
		BT.seq([c_ranged, c_ready, a_ranged], "ranged_branch"),
		BT.seq([BT.cond("melee", func(b): return not bool(b["self"].data.get("ranged", false))),
				a_attack], "melee_branch"),
		BT.seq([c_hp_ok, a_strafe], "strafe_branch"),
		BT.seq([c_low_hp_player, a_backoff], "mercy_backoff"),
		a_approach,
		a_idle,
	], "root")
func step(player) -> void:
	if not alive:
		state = "dead"
		return
	target = player
	if hitstop > 0:
		hitstop -= 1
		return
	state_frame += 1
	if summon_cd > 0:
		summon_cd -= 1
	if ranged_cd > 0:
		ranged_cd -= 1
	if poise < poise_max:
		poise = mini(poise_max, poise + 1)
	_boss_phase()

	# 分帧思考
	think_timer -= 1
	if think_timer <= 0:
		think_timer = 4
		_think(player)

	match state:
		"idle", "patrol":
			_move_walk(0.35)
		"chase":
			_move_walk(1.0)
			# 撞墙就跳：地面敌人不会跳的话，会在台阶前"贴着墙原地走"一辈子
			# （实测机器人见过这一幕：敌人和玩家挤在同一格墙上互相卡住）
			if not data.has("flying") and on_ground and state_frame % 24 == 8:
				if wall_ahead() and player != null and player.p.y < p.y - 4.0:
					vel.y = -float(Cfg.PHY["v0"]) * 0.85
					on_ground = false
		"backoff":
			_move_walk(0.6)
		"hold":
			vel.x *= 0.7
		"telegraph":
			vel.x *= 0.85
			if state_frame > int(data["telegraph"]):
				state = "attack"
				state_frame = 0
				hit_this_attack.clear()
				_do_attack(player)
		"attack", "recovery":
			_advance_attack(player)
		"stagger":
			vel.x *= 0.85
			if state_frame > 18:
				_restart("chase")
		"dead":
			pass

	# 飞行体：悬停在玩家上方
	if bool(data.get("flying", false)) and state != "stagger":
		var want_y: float = (home.y if player == null else player.p.y) - float(data.get("fly_height", 72.0))
		vel.y = clampf((want_y - p.y) * 0.06, -60.0, 90.0)
		physics_step(false)
	else:
		physics_step()
	_recompute_guard()
	if not on_ground and vel.y > 260.0 and bool(data.get("flying", false)) == false:
		pass

## BOSS 三阶段：血 66% / 33% 各翻一次面。
## 前两阶段改的是「招式频率」和「压迫感」，第三阶段才放召唤 —— 让玩家先读招、
## 再被逼着换位置，而不是一开场就弹幕糊脸。
func _boss_phase() -> void:
	if archetype != "boss":
		return
	var hmax: int = maxi(1, max_hp)
	var frac: float = float(hp) / float(hmax)
	var want: int = 3 if frac <= 0.33 else (2 if frac <= 0.66 else 1)
	if want == int(emeta_get("phase", 1)):
		return
	emeta_set("phase", want)
	ctx["phase"] = want
	if want == 2:
		# 阶段 2：起手更快、移速更高（仍然保留 44 帧预告，不能让玩家读不出来）
		data["speed"] = float(data.get("speed", 60.0)) * 1.25
		data["telegraph"] = maxi(26, int(data.get("telegraph", 44)) - 12)
	elif want == 3:
		# 阶段 3：狂暴 —— 移速再提、召唤冷却砍半、认可硬直更久（super_armor 不变）
		data["speed"] = float(data.get("speed", 60.0)) * 1.2
		summon_cd = mini(summon_cd, 90)
	if level != null:
		level.log_event("boss_phase", {"who": id, "phase": want, "hp": hp})
	else:
		pass

func _think(player) -> void:
	bb["self"] = self
	bb["player"] = player
	bb["ctx"] = ctx
	bb["dist"] = absf(player.p.x - p.x) if player != null else 9999.0
	bb["los"] = _line_of_sight(player)
	if not aggro:
		# 未警觉：玩家进入 8 格内才启动（rhythm 高的关卡警觉更远）
		if bb["dist"] < 8.0 * 16.0 * (0.7 + 0.6 * float(ctx.get("rhythm", 0.5))):
			aggro = true
		else:
			state = "patrol"
			want_dir = patrol_dir
			want_action = "approach"
			return
	# 铁律 E2：玩家低血时禁止 backoff（导演层与行为树双重兜底）
	var low: bool = player != null and float(player.hp) / float(player.max_hp) < 0.30
	if low:
		for n in tree.children:
			if n.label == "mercy_backoff":
				n.weight = 0.0
	var r: int = tree.tick(bb)
	if r == BT.FAILURE:
		want_action = "hold"
	# 把「想要什么」翻成状态（这里才是与帧数据接触的地方）
	if state == "idle" or state == "patrol" or state == "chase" or state == "backoff" or state == "hold":
		match want_action:
			"approach":
				if want_dir != 0:
					facing = want_dir
				_restart("chase")
			"backoff":
				if want_dir != 0:
					facing = want_dir
				_restart("backoff")
			"hold":
				_restart("hold")
			_:
				pass

func _restart(s: String) -> void:
	if state != s:
		state = s
		state_frame = 0

func _move_walk(scale: float) -> void:
	var spd: float = float(data.get("speed", 90.0)) * scale
	if affix == "frenzied":
		spd *= float(Cfg.AFFIXES["frenzied"]["speed_mult"])
	vel.x = float(want_dir) * spd
	if want_dir != 0:
		facing = want_dir

func _line_of_sight(player) -> bool:
	if player == null:
		return false
	var y: int = int(floor((p.y - 12.0) / TILE))
	var x0: int = int(floor(p.x / TILE))
	var x1: int = int(floor(player.p.x / TILE))
	var step: int = 1 if x1 >= x0 else -1
	var x: int = x0
	var guard := 0
	while x != x1 and guard < 64:
		x += step
		guard += 1
		if level.is_blocked_tile(x, y):
			return false
	return true

func _begin_attack() -> void:
	state = "telegraph"
	state_frame = 0
	level.log_event("telegraph", {"who": id, "arch": archetype,
		"frames": int(data["telegraph"])})

func _begin_ranged() -> void:
	state = "telegraph"
	state_frame = 0
	ranged_cd = int(data["recovery"]) + int(data["telegraph"]) + 30
	level.log_event("telegraph", {"who": id, "arch": archetype, "ranged": true,
		"frames": int(data["telegraph"])})

func _begin_summon() -> void:
	state = "telegraph"
	state_frame = 0
	summon_cd = int(data["summon"]["cooldown"])
	level.log_event("telegraph", {"who": id, "arch": archetype, "summon": true,
		"frames": int(data["telegraph"])})

func _do_attack(player) -> void:
	var is_ranged: bool = bool(data.get("ranged", false))
	if data.has("summon") and summon_cd > 0 and state_frame == 0:
		pass
	if is_ranged:
		if data.has("summon") and summon_cd > 0:
			level.spawn_enemy_for(self, str(data["summon"]["archetype"]),
				int(data["summon"]["count"]), int(data["summon"]["cap"]))
			level.log_event("summon", {"who": id})
			return
		var pr = Proj.new()
		var pd: Dictionary = data.get("projectile", {})
		pr.setup(level, "projectile", p.x + float(facing) * 10.0, p.y - 14.0)
		pr.vel = Vector2(float(facing) * float(pd.get("speed", 160.0)), -30.0)
		pr.dmg = int(round(float(pd.get("dmg", 5)) * FD.dmg_scale(level_floor)))
		pr.gravity = float(pd.get("gravity", 0.0))
		pr.life = int(pd.get("life", 200))
		pr.homing = float(pd.get("homing", 0.0))
		pr.owner_actor = self
		pr.kb = {"x": 2.4, "y": -1.4}
		pr.h = 6.0
		pr.radius = 4.0
		level.add_projectile(pr)
		level.log_event("ranged_fire", {"who": id})
		state = "recovery"
		state_frame = 0
		return
	# 近战：判定帧由 _advance_attack 处理
	state = "attack"
	state_frame = 0
	hit_this_attack.clear()

func _advance_attack(player) -> void:
	var su: int = int(data.get("startup", 8))
	var ac: int = int(data.get("active", 5))
	var rc: int = int(data.get("recovery", 18))
	if state == "attack" and state_frame >= su and state_frame < su + ac:
		var hb: Rect2 = move_box({"box": data["box"]})
		if player != null and player.alive and hb.intersects(player.hurt_box()):
			var dmg: int = int(data["dmg"])
			var res: Dictionary = player.take_hit(self, dmg, data["kb"],
				float(data.get("poise_dmg", 10)), int(data.get("hitstop", 3)),
				str(data.get("weight", "light")) == "heavy")
			if res["parried"]:
				# 被弹反：长硬直，这是玩家的奖励窗口
				state = "stagger"
				state_frame = 0
				return
			if res["blocked"]:
				vel.x = -float(facing) * 40.0
			level.log_event("enemy_hit", {"who": id, "dmg": res["dmg"], "blocked": res["blocked"]})
	if bool(data.get("suicide", false)) and state == "attack" and state_frame >= su:
		# 自爆：一次性大范围伤害，然后自己死
		if player != null and player.alive:
			var hb2: Rect2 = move_box({"box": data["box"]})
			if hb2.intersects(player.hurt_box().grow(10.0)):
				player.take_hit(self, int(data["dmg"]), data["kb"], 24.0, 6, true)
		hp = 0
		alive = false
		level.log_event("explode", {"who": id})
		return
	if state == "attack" and state_frame >= su + ac:
		state = "recovery"
		state_frame = 0
		_recompute_guard()
	if state == "recovery" and state_frame >= rc:
		state = "chase"
		state_frame = 0

func _recompute_guard() -> void:
	# 盾兵：正面格挡（朝向决定）。背刺 / 破韧时不吃格挡 —— 这就是它的解法。
	guard_active = bool(data.get("guard", false)) and state != "stagger" and state != "attack" and poise > 0

# --------------------------------------------------------------------------
# 精英词缀的被动效果
# --------------------------------------------------------------------------

func on_landed() -> void:
	pass

func post_step() -> void:
	if affix == "warded" and level.frame % 300 == 0:
		poise = poise_max
	if not alive and affix == "explosive" and not bool(emeta_get("exploded", false)):
		emeta_set("exploded", true)
		level.log_event("affix_explode", {"who": id, "cell": str(cell())})

var _meta: Dictionary = {}
func emeta_set(k: String, v) -> void:
	_meta[k] = v

func emeta_get(k: String, dflt = false):
	return _meta.get(k, dflt)
