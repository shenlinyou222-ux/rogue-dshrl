# Items —— 道具 / 武器 / 掉落 / 合成（留好口子）
#
# 掉落三件事必须分清，否则代码会烂：
#   1. **生成**（什么稀有度、什么词条）= 纯函数 f(seed, 房间, 幸运值)，可重放；
#   2. **拾取**（谁捡到、什么时候）= 运行时行为，写事件日志；
#   3. **合成**（两件 → 一件）= 配方表 + 融合口子（§10.4）。
#
# 合成从第一天就留口子，不做完整系统：配方用「标签匹配」而不是硬编码 id，
# 这样后面加武器不需要改配方代码。
#   融合规则（可扩展）：
#     同槽位 + 同稀有度 → 升一档稀有度，词条取并集（最多 3 条）
#     同槽位 + 不同稀有度 → 结果取较高档，但随机继承低档的一条词条
#     词条冲突（互斥标签）→ 保留先放入的那件

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const Rng = preload("res://core/rng.gd")
const Dig = preload("res://core/digest.gd")

## 武器原型（美术占位：用形状 + 颜色描述，后期换成贴图）
const WEAPONS := {
	"shortsword": {"tags": ["melee", "fast"], "dmg": 1.00, "reach": 1.0, "name": "短剑", "shape": "blade"},
	"greataxe":   {"tags": ["melee", "heavy"], "dmg": 1.55, "reach": 1.25, "name": "巨斧", "shape": "axe"},
	"spear":      {"tags": ["melee", "reach"], "dmg": 1.15, "reach": 1.6, "name": "长枪", "shape": "spear"},
	"dagger":     {"tags": ["melee", "fast", "crit"], "dmg": 0.75, "reach": 0.85, "name": "匕首", "shape": "dagger"},
	"bow":        {"tags": ["ranged"], "dmg": 0.9, "reach": 3.0, "name": "弓", "shape": "bow"},
}

const AFFIX_POOL := [
	{"id": "sharp", "name": "锐利", "power_bonus": 0.10, "tags": ["dmg"]},
	{"id": "swift", "name": "迅捷", "speed_bonus": 0.08, "tags": ["speed"]},
	{"id": "nimble", "name": "轻盈", "roll_invuln_bonus": 3, "tags": ["defense"]},
	{"id": "vampiric", "name": "汲血", "leech": 1, "tags": ["dmg", "defense"]},
	{"id": "thorn", "name": "荆棘", "thorns": 2, "tags": ["defense"]},
	{"id": "heavy", "name": "沉重", "power_bonus": 0.18, "knock_bonus": 0.25, "tags": ["dmg"]},
	{"id": "frugal", "name": "节俭", "stamina_bonus": 20.0, "tags": ["speed"]},
]

## 互斥标签对（合成时用来判冲突）
const CONFLICT_PAIRS := [["speed", "heavy"], ["dmg", "frugal"]]

# --------------------------------------------------------------------------
# 生成
# --------------------------------------------------------------------------

## 纯函数：同 (seed, index, luck, floor) ⇒ 同一件道具。
static func roll_item(version_key: String, seed64: int, floor_index: int, index: int,
					  luck: float, kind: String = "weapon") -> Dictionary:
	var rnd = Rng.at(version_key, seed64, floor_index, "loot", index)
	var rar: int = rnd.pick_rarity(_curve(luck))
	var rname: String = str(Cfg.RARITY[rar])
	var power: float = float(Cfg.RARITY_POWER[rname])
	var n_affix: int = int(Cfg.RARITY_AFFIX_COUNT[rname])

	var item := {
		"id": "%s_%d_%d" % [kind, floor_index, index],
		"kind": kind,
		"rarity": rar,
		"rarity_name": rname,
		"base_power": power,
		"power_bonus": power - 1.0,
		"tags": [],
		"affixes": [],
		"slot": "weapon_a",
		"name": "",
		"shape": "blade",
		"color": 0,
	}
	if kind == "weapon":
		var keys: Array = WEAPONS.keys()
		var proto: String = str(keys[rnd.range_i(keys.size())])
		var w: Dictionary = WEAPONS[proto]
		item["name"] = str(w["name"])
		item["shape"] = str(w["shape"])
		item["tags"] = (w["tags"] as Array).duplicate()
		item["power_bonus"] = float(item["power_bonus"]) + (float(w["dmg"]) - 1.0)
		item["reach_mult"] = float(w["reach"])
	elif kind == "amulet":
		item["slot"] = "amulet"
		item["name"] = "护符"
		item["tags"] = ["defense"]
	elif kind == "skill":
		item["slot"] = "skill_1" if index % 2 == 0 else "skill_2"
		item["name"] = "战技"
		item["tags"] = ["skill"]
		item["cooldown"] = 180 - rar * 20
	elif kind == "currency":
		item["name"] = "碎片"
		item["amount"] = 5 + rar * 10

	# 词条：按稀有度阶梯抽，且**不重复**
	var pool: Array = AFFIX_POOL.duplicate()
	var picked: Array = []
	for i in range(n_affix):
		if pool.is_empty():
			break
		var idx: int = rnd.range_i(pool.size())
		var a: Dictionary = pool[idx]
		pool.remove_at(idx)
		picked.append(a)
		item["affixes"].append(a["id"])
		for k in a.keys():
			if k == "power_bonus" or k == "speed_bonus" or k == "stamina_bonus":
				item[k] = float(item.get(k, 0.0)) + float(a[k])
			elif k == "roll_invuln_bonus" or k == "thorns" or k == "leech":
				item[k] = int(item.get(k, 0)) + int(a[k])
	item["color"] = rar
	return item

static func _curve(luck: float) -> Array:
	var base: Array = Cfg.RARITY_CURVE
	var w: Array = []
	for i in range(base.size()):
		var f := 1.0
		if i > 0:
			f = pow(maxf(0.2, luck), float(i))
		w.append(float(base[i]) * f)
	var total := 0.0
	for x in w:
		total += x
	var out: Array = []
	for x2 in w:
		out.append(x2 / total)
	return out

static func describe(item: Dictionary) -> String:
	var s: String = "★%d %s" % [int(item.get("rarity", 0)) + 1, str(item.get("name", "?"))]
	var aff: Array = item.get("affixes", [])
	if not aff.is_empty():
		var names: Array = []
		for a in aff:
			for p in AFFIX_POOL:
				if p["id"] == a:
					names.append(p["name"])
		s += "（%s）" % "·".join(names)
	return s

# --------------------------------------------------------------------------
# 合成（口子：配方用标签匹配，不硬编码 id）
# --------------------------------------------------------------------------

static func can_fuse(a: Dictionary, b: Dictionary) -> Dictionary:
	if a.is_empty() or b.is_empty():
		return {"ok": false, "why": "空槽位"}
	if str(a.get("kind", "")) != str(b.get("kind", "")):
		return {"ok": false, "why": "类型不同（%s vs %s）" % [a.get("kind", "?"), b.get("kind", "?")]}
	if int(a.get("rarity", 0)) != int(b.get("rarity", 0)):
		return {"ok": false, "why": "稀有度必须相同（用「融合」规则请走 fuse_any）"}
	# 互斥标签检查
	for pair in CONFLICT_PAIRS:
		var has_a0: bool = pair[0] in a.get("tags", []) or pair[0] in a.get("affixes", [])
		var has_b1: bool = pair[1] in b.get("tags", []) or pair[1] in b.get("affixes", [])
		if has_a0 and has_b1:
			return {"ok": false, "why": "词条互斥（%s × %s）" % [pair[0], pair[1]]}
	return {"ok": true, "why": ""}

## 融合：任意两件同类型 → 取较高稀有度 +1 档（有上限），词条取并集（最多 3 条）
static func fuse(a: Dictionary, b: Dictionary, index: int) -> Dictionary:
	if str(a.get("kind", "")) != str(b.get("kind", "")):
		return {}
	var rar: int = mini(int(Cfg.RARITY.size()) - 1, maxi(int(a.get("rarity", 0)), int(b.get("rarity", 0))) + 1)
	var out: Dictionary = a.duplicate(true)
	out["rarity"] = rar
	out["rarity_name"] = str(Cfg.RARITY[rar])
	out["base_power"] = Cfg.RARITY_POWER[str(Cfg.RARITY[rar])]
	out["power_bonus"] = float(out["base_power"]) - 1.0
	var affs: Array = []
	for src in [a, b]:
		for x in src.get("affixes", []):
			if not (x in affs):
				affs.append(x)
	if affs.size() > 3:
		affs = affs.slice(0, 3)
	out["affixes"] = affs
	out["id"] = "%s_fused_%d" % [str(out.get("id", "x")), index]
	out["name"] = "%s·改" % str(a.get("name", "?"))
	out["fused_from"] = [a.get("id", "?"), b.get("id", "?")]
	return out
