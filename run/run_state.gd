# RunState —— 一局的编排：3 层推进 / 死亡 / meta 成长 / 存档
#
# 分工：
#   RunGen   = 纯生成（世界线，同种子同局）
#   Level    = 单层运行时（战斗、机关、掉落）
#   RunState = 把楼层串起来 + 处理死亡与跨局成长
#
# 肉鸽循环的落点（§11）：
#   层内：击杀 → 掉落 → 装备 → 变强（一局之内）
#   跨层：钥匙 / 层数推进 / 精英奖励
#   跨局：meta 成长（细胞）→ 解锁变异 → 改变**下一局**的 θ 与初始装备
#   θ 只在局间生效：这是「同一局内部世界线不被中途改动」的实现方式。

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const RunGen = preload("res://gen/run_gen.gd")
const Heads = preload("res://gen/heads.gd")
const Level = preload("res://run/level.gd")
const Player = preload("res://actors/player.gd")
const Items = preload("res://loot/items.gd")
const Directors = preload("res://ai/director.gd")

class Meta:
	var cells: int = 0                  # 细胞（元货币）
	var runs: int = 0
	var wins: int = 0
	var best_floor: int = 1
	var mutation: String = "brutality"
	var unlocked: Dictionary = {"weapon_a": true, "amulet": true, "skill_1": true}
	var theta: Dictionary = {}

	func to_dict() -> Dictionary:
		return {"cells": cells, "runs": runs, "wins": wins, "best_floor": best_floor,
				"mutation": mutation, "unlocked": unlocked, "theta": theta}

	func from_dict(d: Dictionary) -> void:
		cells = int(d.get("cells", 0))
		runs = int(d.get("runs", 0))
		wins = int(d.get("wins", 0))
		best_floor = int(d.get("best_floor", 1))
		mutation = str(d.get("mutation", "brutality"))
		unlocked = d.get("unlocked", unlocked)
		theta = d.get("theta", {})

const MUTATIONS := {
	"brutality": {"desc": "残暴：击杀回血 + 伤害 +10%", "power": 0.10, "on_kill_heal": 2},
	"tactics":   {"desc": "战术：翻滚无敌帧 +4，技能 CD -20%", "roll_invuln": 4, "skill_cd": 0.8},
	"survival":  {"desc": "生存：最大生命 +25，格挡减伤更强", "max_hp": 25, "block_mult": 0.12},
}

var meta = Meta.new()
var spec = null
var levelset = null
var level = null
var player = null
var director = null
var floor_index: int = 1
var state: String = "playing"       # playing / floor_clear / dead / won
var save_path: String = "user://dshrl_meta.json"

func _init(seed64: int = 0, use_model: bool = false, theta: Dictionary = {}) -> void:
	load_meta()
	var th: Dictionary = theta.duplicate()
	if th.is_empty():
		th = meta.theta.duplicate()
	if th.is_empty():
		th = Cfg.THETA_DEFAULT.duplicate()
	spec = Heads.make_run_spec(seed64, th)
	director = Directors.new(use_model)
	player = Player.new()
	_apply_meta_to_player()

func _apply_meta_to_player() -> void:
	var m: Dictionary = MUTATIONS.get(meta.mutation, MUTATIONS["brutality"])
	player.max_hp = 100 + int(m.get("max_hp", 0))
	player.hp = player.max_hp
	player.extra_roll_invuln = int(m.get("roll_invuln", 0))
	player.mutation = meta.mutation
	player.on_kill_heal = int(m.get("on_kill_heal", 0))
	# 跨局 cell 投入：每 5 个细胞换 1 点初始力量（上限 +50%）
	player.add_power(minf(0.5, float(meta.cells / 5) * 0.02))
	player.equip("weapon_a", Items.roll_item(Cfg.VERSION_KEY, spec.seed64, 1, 9999, 0.5, "weapon"))

## 生成整局（约 1 s；一次性生成 3 层，保证世界线在同一进程内不被重入修改）
func generate() -> void:
	levelset = RunGen.build(spec)
	meta.runs += 1

func start_floor(idx: int) -> void:
	floor_index = idx
	var lv = levelset.levels[idx - 1]
	level = Level.new()
	level.build(lv.floor, idx, spec, player, director,
		lv.enemies, lv.loot, lv.decor, lv.event)
	level.pacing_frames = 180
	level.loot_rarity_delta = 0
	level.hint_text = ""
	state = "playing"

func step(input: Dictionary) -> void:
	if state != "playing":
		return
	level.step(input)
	# 变异效果：击杀回血
	var m: Dictionary = MUTATIONS.get(meta.mutation, {})
	if m.has("on_kill_heal"):
		pass
	if level.failed:
		state = "dead"
		meta.cells += _cells_earned()
		meta.best_floor = maxi(meta.best_floor, floor_index)
		save_meta()
	elif level.finished:
		_on_floor_clear()

func _on_floor_clear() -> void:
	meta.cells += int(Cfg.RUN["cell_per_elite"]) * 0 + 3
	var heal: int = int(round(float(player.max_hp) * 0.25))
	player.hp = mini(player.max_hp, player.hp + heal)
	if floor_index >= int(Cfg.RUN["floors"]):
		state = "won"
		meta.wins += 1
		meta.cells += int(Cfg.RUN["cell_per_boss"])
		save_meta()
	else:
		state = "floor_clear"

func next_floor() -> void:
	if state != "floor_clear":
		return
	start_floor(floor_index + 1)

func _cells_earned() -> int:
	return 1 + level.total_kills / 10 + floor_index

# --------------------------------------------------------------------------
# 存档（JSON；meta 是跨局的唯一持久状态）
# --------------------------------------------------------------------------

func load_meta() -> void:
	if not FileAccess.file_exists(save_path):
		meta = Meta.new()
		meta.theta = Cfg.THETA_DEFAULT.duplicate()
		return
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var d = JSON.parse_string(txt)
	if typeof(d) == TYPE_DICTIONARY:
		meta.from_dict(d)

func save_meta() -> void:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(meta.to_dict(), "  "))
	f.close()

## θ 的调整只影响**下一局**（局内冻结，§8.3）
func set_theta(key: String, value: int) -> void:
	if not (key in Cfg.THETA_KEYS):
		return
	meta.theta[key] = clampi(value, 0, 100)
	save_meta()

func stats_line() -> String:
	return "层 %d/%d · 生命 %d/%d · 碎片 %d · 击杀 %d · 细胞 %d" % [
		floor_index, int(Cfg.RUN["floors"]), player.hp, player.max_hp,
		player.money, level.total_kills if level != null else 0, meta.cells]
