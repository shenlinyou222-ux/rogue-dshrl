# Heads —— 六个生成头（§8.2）
#
#   layout → room → enemy → loot → event → decor
#
# 三条铁律（地图方案 §9）：
#   1. **每头一条独立 RNG 流**。加一个头 / 改一个头的参数，绝不能把别的头的
#      输出错位（否则「同种子同关卡」当场作废）。所以每条流都用
#      Rng.stream(version, seed, floor, head, tag)，head 直接进哈希键。
#   2. **头与头之间只通过「规格 + 上一步产物」通信**，不共享可变状态。
#      enemy 头读的是 room 头的输出，不读 room 头用过的随机数。
#   3. **每个头自己的输出都必须能独立验证**（validate.gd 里逐条断言），
#      不许出现「只有六个头合起来才说得通」的约束。

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const Rng = preload("res://core/rng.gd")
const Dig = preload("res://core/digest.gd")

# --------------------------------------------------------------------------
# 产物类型
# --------------------------------------------------------------------------

class EnemySpawn:
	var cell: Vector2i = Vector2i.ZERO
	var archetype: String = "rusher"
	var elite: bool = false
	var affix: String = ""
	var room_index: int = 0
	var room_type: String = "normal"
	var threat: int = 0
	var facing: int = -1

class LootSpawn:
	var cell: Vector2i = Vector2i.ZERO
	var kind: String = "chest"        # chest / pickup / weapon / currency
	var item_id: String = ""
	var rarity: int = 0
	var room_index: int = 0

class Decor:
	var cell: Vector2i = Vector2i.ZERO
	var kind: String = "torch"
	var seed_v: int = 0

class EventSpec:
	var affix: String = ""
	var curse: String = ""
	var theme: String = "crypt"
	var message: String = ""

# --------------------------------------------------------------------------
# spec —— 一局 / 一层的规格（θ 只影响**下一局**，局内冻结，§8.3）
# --------------------------------------------------------------------------

class RunSpec:
	var version_key: String = Cfg.VERSION_KEY
	var seed64: int = 0
	var theta: Dictionary = {}
	var floors: int = int(Cfg.RUN["floors"])

	func theta_v(key: String) -> int:
		return int(theta.get(key, Cfg.THETA_DEFAULT.get(key, 50)))

	## θ 归一化到 [0, 1]，生成头统一用这个，免得每个头各写一套映射。
	func theta_f(key: String) -> float:
		return float(theta_v(key)) / 100.0

	func fingerprint() -> String:
		var parts: Array = [version_key, str(seed64)]
		for k in Cfg.THETA_KEYS:
			parts.append("%s=%d" % [k, theta_v(k)])
		return Dig.fingerprint("|".join(parts), 12)

static func make_run_spec(seed64: int, theta: Dictionary = {}) -> Object:
	var s = RunSpec.new()
	s.seed64 = seed64
	var th := {}
	for k in Cfg.THETA_KEYS:
		th[k] = int(theta.get(k, Cfg.THETA_DEFAULT[k]))
	s.theta = th
	return s

# --------------------------------------------------------------------------
# enemy 头
# --------------------------------------------------------------------------

## 威胁预算（§7.2）：每房 cap = 6 + 2*floor，全层总预算按难度契约缩放。
static func threat_cap(floor_index: int, theta) -> int:
	var base: int = int(Cfg.DIFFICULTY["threat_cap_base"]) \
		+ int(Cfg.DIFFICULTY["threat_cap_per_floor"]) * (floor_index - 1)
	# 难度 θ 上下 ±40% 之内浮动，永远不突破屏幕敌人上限
	var scaled: int = int(round(float(base) * (0.6 + 0.8 * theta.theta_f("difficulty"))))
	return clampi(scaled, 4, int(Cfg.DIFFICULTY["max_enemies_screen"]))

## 房间**有效**威胁预算 —— 生成头与校验器必须用同一个函数算，
## 否则就会「生成头按自己的算法放怪、校验器按另一套算法判超预算」，
## 这种不一致实测直接导致 X2 大量误报（10 局里 7 局报错）。
static func effective_cap(floor_index: int, rtype: String, theta) -> int:
	var cap: int = threat_cap(floor_index, theta)
	var density: float = 0.55 + 0.9 * theta.theta_f("combat_density")
	match rtype:
		"normal":
			cap = int(round(float(cap) * density))
		"treasure":
			cap = int(round(float(cap) * density * 0.6))
		"elite", "boss":
			cap = int(round(float(cap) * float(Cfg.ELITE_THREAT_MULT)))
		_:
			pass
	return clampi(cap, 2, int(Cfg.DIFFICULTY["max_enemies_screen"]))

## 房间类型 -> 允许的敌人原型权重（每种房间有自己的语义）
static func _archetype_weights(rtype: String) -> Dictionary:
	match rtype:
		"start":
			return {}
		"rest", "shop":
			return {}
		"treasure":
			return {"rusher": 5, "flyer": 3, "exploder": 2}
		"secret":
			return {"brute": 4, "caster": 3, "shielded": 3}
		"elite":
			return {"brute": 5, "shielded": 4, "caster": 3, "summoner": 3}
		"boss":
			return {"brute": 6, "summoner": 4, "caster": 4}
		_:
			return {"rusher": 6, "archer": 4, "shielded": 4, "exploder": 3,
					"flyer": 3, "caster": 2, "brute": 2, "summoner": 1}

static func enemy_head(floor, spec, theta) -> Array:
	var rnd = Rng.stream(spec.version_key, spec.seed64, floor.floor_index, "enemy", "v1")
	var out: Array = []
	var max_screen: int = int(Cfg.DIFFICULTY["max_enemies_screen"])
	var rows: int = floor.rooms.size()
	for i in range(rows):
		var fr = floor.rooms[i]
		var weights: Dictionary = _archetype_weights(fr.rtype)
		if weights.is_empty():
			continue
		var cap: int = effective_cap(floor.floor_index, fr.rtype, theta)
		# 候选槽：离门至少 5 格，槽与槽之间至少 4 格（不许挤成一堆）
		var cand: Array = []
		var used: Array = []
		for s in fr.slots:
			var lx: int = s.x - fr.x0
			if lx < 5 or lx > fr.w - 5:
				continue
			var too_close := false
			for u in used:
				if absi(u.x - s.x) < 4 and absi(u.y - s.y) < 6:
					too_close = true
					break
			if too_close:
				continue
			cand.append(s)
			used.append(s)
		cand = rnd.shuffle(cand)
		var spent := 0
		var placed := 0
		var want_elite: bool = fr.rtype == "elite" or fr.rtype == "secret" or fr.rtype == "boss"
		for s2 in cand:
			if placed >= 8:
				break
			# elite / boss 房第一只必出重甲，保证「有解法」的敌人一定在场
			var arch: String
			if want_elite and placed == 0:
				var heavy: Array = ["brute", "shielded", "summoner"]
				arch = str(heavy[rnd.range_i(heavy.size())])
			else:
				var keys: Array = weights.keys()
				var ws: Array = []
				for k in keys:
					ws.append(weights[k])
				arch = str(rnd.pick_weighted(keys, ws))
			var threat: int = int(Cfg.ARCHETYPES[arch]["threat"])
			var is_elite: bool = false
			var mult := 1.0
			if fr.rtype == "elite" or fr.rtype == "boss" or fr.rtype == "secret":
				mult = float(Cfg.ELITE_THREAT_MULT) if placed == 0 else 1.0
			if mult > 1.0:
				is_elite = true
				threat = int(round(float(threat) * float(Cfg.ELITE_THREAT_MULT)))
			if spent + threat > cap:
				continue
			var sp = EnemySpawn.new()
			sp.cell = s2
			sp.archetype = arch
			sp.elite = is_elite
			sp.room_index = i
			sp.room_type = fr.rtype
			sp.threat = threat
			sp.facing = -1 if int(s2.x) > int(fr.entry_cell.x) else 1
			if is_elite:
				sp.affix = _roll_affix(arch, rnd)
			out.append(sp)
			spent += threat
			placed += 1
	return out

## 精英词缀：caster/summoner 不得吃「召唤」词缀（§7.3 硬约束）
static func _roll_affix(arch: String, rnd) -> String:
	var pool: Array = []
	for k in Cfg.AFFIXES.keys():
		var forb: Array = Cfg.AFFIXES[k]["forbidden_on"]
		if arch in forb:
			continue
		pool.append(k)
	if pool.is_empty():
		return ""
	return str(pool[rnd.range_i(pool.size())])

# --------------------------------------------------------------------------
# loot 头
# --------------------------------------------------------------------------

static func loot_head(floor, spec, theta) -> Array:
	var rnd = Rng.stream(spec.version_key, spec.seed64, floor.floor_index, "loot", "v1")
	var out: Array = []
	var luck: float = 0.5 + theta.theta_f("loot")       # 0.5 ~ 1.5
	for i in range(floor.rooms.size()):
		var fr = floor.rooms[i]
		var n_chest := 0
		match fr.rtype:
			"start": n_chest = 0
			"treasure": n_chest = 3 + rnd.range_i(2)
			"secret": n_chest = 2
			"shop": n_chest = 1
			"elite": n_chest = 1
			"boss": n_chest = 2
			_: n_chest = 1 if rnd.chance(int(22.0 * luck)) else 0
		var pool: Array = rnd.shuffle(fr.slots.duplicate())
		for k in range(mini(n_chest, pool.size())):
			var d = LootSpawn.new()
			d.cell = pool[k]
			d.room_index = i
			d.kind = "chest" if fr.rtype == "treasure" or fr.rtype == "secret" else "pickup"
			d.rarity = rnd.pick_rarity(_shift_curve(luck))
			out.append(d)
	return out

## 幸运值把掉落曲线往高稀有度方向掰（θ.loot 的直接效果）。
static func _shift_curve(luck: float) -> Array:
	var base: Array = Cfg.RARITY_CURVE
	var w: Array = []
	for i in range(base.size()):
		var f := 1.0
		if i > 0:
			f = pow(luck, float(i))
		w.append(float(base[i]) * f)
	var total := 0.0
	for x in w:
		total += x
	var out: Array = []
	for x in w:
		out.append(x / total)
	return out

# --------------------------------------------------------------------------
# event 头（层主题 + 诅咒 + 精英词缀池）
# --------------------------------------------------------------------------

static func event_head(floor, spec, theta) -> Object:
	var rnd = Rng.stream(spec.version_key, spec.seed64, floor.floor_index, "event", "v1")
	var e = EventSpec.new()
	var nar: float = theta.theta_f("narrative")
	var ti: int = clampi(int(round(nar * float(Cfg.THEMES.size() - 1))), 0, Cfg.THEMES.size() - 1)
	# 主题在层内固定，但允许一个小抖动 —— 同一局的种子下仍然确定
	e.theme = str(Cfg.THEMES[ti]) if rnd.chance(75) else str(rnd.pick(Cfg.THEMES))
	var risk: float = theta.theta_f("risk")
	if rnd.chance(int(20.0 + 45.0 * risk)):
		var curses: Array = ["血月（敌人 +15% 移速，掉落 +1 稀有度）",
							 "贫瘠（本层不掉落货币，宝箱必出武器）",
							 "回响（同房敌人共享警觉）",
							 "易碎（受伤 +20%，无敌帧 +6 帧）"]
		e.curse = str(curses[rnd.range_i(curses.size())])
	e.affix = _roll_affix("rusher", rnd)
	e.message = "%s · %s" % [e.theme, e.curse if e.curse != "" else "平静"]
	return e

# --------------------------------------------------------------------------
# decor 头（纯装饰，绝不参与可达性 —— G9）
# --------------------------------------------------------------------------

static func decor_head(floor, spec) -> Array:
	var rnd = Rng.stream(spec.version_key, spec.seed64, floor.floor_index, "decor", "v1")
	var out: Array = []
	var kinds: Array = ["torch", "banner", "rubble", "chain", "moss"]
	for i in range(floor.rooms.size()):
		var fr = floor.rooms[i]
		var n: int = 4 + rnd.range_i(6)
		for k in range(n):
			if fr.slots.is_empty():
				break
			var s: Vector2i = fr.slots[rnd.range_i(fr.slots.size())]
			var d = Decor.new()
			d.cell = Vector2i(s.x, s.y - 1)
			d.kind = str(kinds[rnd.range_i(kinds.size())])
			d.seed_v = rnd.next_u32() & 0xFFFF
			out.append(d)
	return out
