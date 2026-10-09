# RunGen —— 把「一局」拼出来：3 层 × 11 房 + 六头产物
#
# 这是生成层的总入口，也是运行时唯一需要调用的东西：
#
#   var ls = RunGen.build(run_spec)     # 约 1.2 s（3 层）
#   ls.floors[0].map / .enemies / .loot / .event / .decor
#
# 为什么一次性把 3 层全生成：
#   1. 世界线确定性要求「同种子同局」，一次生成避免中途重入；
#   2. 小地图需要全局信息；
#   3. 1.2 s 的开局代价可以接受（有加载画面）。
#
# 每个头都用**独立 RNG 流**（Rng.stream(version, seed, floor, head, tag)），
# 所以给某个头加一个参数，不会污染其它头的输出。

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const Dig = preload("res://core/digest.gd")
const Rng = preload("res://core/rng.gd")
const Layout = preload("res://gen/layout.gd")
const Heads = preload("res://gen/heads.gd")
const Validate = preload("res://gen/validate.gd")

class Level:
	var floor_index: int = 1
	var floor = null                 # Layout.Floor
	var enemies: Array = []          # Heads.EnemySpawn
	var loot: Array = []             # Heads.LootSpawn
	var decor: Array = []            # Heads.Decor
	var event = null                 # Heads.EventSpec
	var errors: Array = []

	func map():
		return floor.map

class RunLevelSet:
	var spec = null
	var levels: Array = []
	var errors: Array = []
	var gen_ms: int = 0
	var fingerprint: String = ""

	func level(i: int):
		return levels[i]

	func total_enemies() -> int:
		var n := 0
		for l in levels:
			n += l.enemies.size()
		return n

	func total_rooms() -> int:
		var n := 0
		for l in levels:
			n += l.floor.rooms.size()
		return n

static func build(spec) -> Object:
	var t0 := Time.get_ticks_msec()
	var ls = RunLevelSet.new()
	ls.spec = spec
	for fl in range(1, spec.floors + 1):
		var f = Layout.build_floor(spec.version_key, spec.seed64, fl, false)
		var lv = Level.new()
		lv.floor_index = fl
		lv.floor = f
		lv.errors.append_array(f.errors)
		lv.enemies = Heads.enemy_head(f, spec, spec)
		lv.loot = Heads.loot_head(f, spec, spec)
		lv.decor = Heads.decor_head(f, spec)
		lv.event = Heads.event_head(f, spec, spec)
		# 层的随机流全部来自 (version, seed, floor, head)，所以 θ 只通过显式参数进入，
		# 不通过随机数序列 —— 改 θ 不会让几何变形（这是「θ 只影响下一局内容」的实现方式）。
		lv.errors.append_array(Validate.check_floor(f, spec, lv.enemies, lv.loot, lv.event, spec))
		ls.levels.append(lv)
		ls.errors.append_array(lv.errors)
	ls.gen_ms = Time.get_ticks_msec() - t0
	ls.fingerprint = _fingerprint(ls)
	return ls

## 全局指纹：关卡几何 + 内容分布，用于「同种子同关卡」的回归测试。
static func _fingerprint(ls) -> String:
	var parts: Array = [ls.spec.version_key, str(ls.spec.seed64), ls.spec.fingerprint()]
	for l in ls.levels:
		parts.append("F%d:%s" % [l.floor_index, l.floor.map.fingerprint()])
		var epos: Array = []
		for e in l.enemies:
			epos.append("%s@%d,%d%s" % [e.archetype, e.cell.x, e.cell.y, e.affix])
		parts.append("E:" + ",".join(epos))
		var lpos: Array = []
		for d in l.loot:
			lpos.append("%s@%d,%d" % [d.kind, d.cell.x, d.cell.y])
		parts.append("L:" + ",".join(lpos))
		parts.append("V:" + l.event.message)
	return Dig.fingerprint("|".join(parts), 16)

## 逐层的内容统计（自检 / 平衡报告用）。
static func stats(ls) -> Dictionary:
	var arch := {}
	var elite := 0
	var threat := 0
	for l in ls.levels:
		for e in l.enemies:
			arch[e.archetype] = int(arch.get(e.archetype, 0)) + 1
			if e.elite:
				elite += 1
			threat += e.threat
	var per_floor: Array = []
	for l in ls.levels:
		per_floor.append(l.enemies.size())
	return {
		"rooms": ls.total_rooms(),
		"enemies": ls.total_enemies(),
		"elite": elite,
		"threat": threat,
		"archetypes": arch,
		"per_floor": per_floor,
		"ms": ls.gen_ms,
	}
