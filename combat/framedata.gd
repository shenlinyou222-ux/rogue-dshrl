# FrameData —— 帧数据（动作的全部手感都在这一张表里）
#
# 设计原则（机制拆解 §5 / §6）：
#   1. **数据驱动**：状态机只认帧号，不写 if 树。改手感 = 改表，不改逻辑。
#   2. **三段式**：startup（起手）→ active（判定）→ recovery（收招）。
#      取消权限只在这些段的边界上定义，所以「能不能取消」是**可枚举**的。
#   3. **取消是位掩码**（CANCEL 常量）：装备/词缀改取消规则 = 改一个 bit，
#      天然可组合，不需要嵌套 if。
#
# 帧数按 60 Hz。所有数值的单位：px、帧。

extends RefCounted

const Cfg = preload("res://core/constants.gd")

# --------------------------------------------------------------------------
# 玩家招式表
# --------------------------------------------------------------------------
# 字段说明：
#   startup/active/recovery  三段帧数
#   dmg        基础伤害
#   mult       连段倍率索引（对应 Cfg.DMG.combo_mult）
#   box        判定位（相对脚底中心，x 向前为正，y 向上为负；w/h 为尺寸）
#   hitstop   命中定格帧数（手感的核心：命中时的"顿"）
#   poise_dmg  削韧
#   kb         击退（水平/垂直 px/帧 的初速）
#   cancel_*   各段允许的取消位（见 Cfg.CANCEL）
#   move       每帧强制位移（前冲/后撤）
#   next       收招后自动接的状态（连段用）
#   gravity    是否受重力（空中招式）
const MOVES := {
	"attack1": {
		"startup": 6, "active": 4, "recovery": 10, "dmg": 9, "mult": 0,
		"box": {"ox": 13, "oy": -19, "w": 24, "h": 20},
		"hitstop": 3, "poise_dmg": 10, "kb": {"x": 2.6, "y": -1.2},
		"cancel_startup": Cfg.CANCEL["KARA"],
		"cancel_active": Cfg.CANCEL["WHIFF"] | Cfg.CANCEL["HIT"],
		"cancel_recovery": Cfg.CANCEL["WHIFF"] | Cfg.CANCEL["HIT"] | Cfg.CANCEL["KARA"],
		"move": {"startup": 0.9, "active": 0.5, "recovery": 0.0},
		"next": "", "chain": "attack2", "gravity": false, "sfx": "swing_light",
	},
	"attack2": {
		"startup": 5, "active": 4, "recovery": 12, "dmg": 11, "mult": 1,
		"box": {"ox": 14, "oy": -18, "w": 26, "h": 22},
		"hitstop": 3, "poise_dmg": 12, "kb": {"x": 3.0, "y": -1.6},
		"cancel_startup": Cfg.CANCEL["KARA"],
		"cancel_active": Cfg.CANCEL["WHIFF"] | Cfg.CANCEL["HIT"],
		"cancel_recovery": Cfg.CANCEL["WHIFF"] | Cfg.CANCEL["HIT"] | Cfg.CANCEL["KARA"],
		"move": {"startup": 1.1, "active": 0.4, "recovery": 0.0},
		"next": "", "chain": "attack3", "gravity": false, "sfx": "swing_light",
	},
	"attack3": {
		"startup": 9, "active": 5, "recovery": 18, "dmg": 18, "mult": 2,
		"box": {"ox": 16, "oy": -17, "w": 30, "h": 26},
		"hitstop": 6, "poise_dmg": 22, "kb": {"x": 4.6, "y": -3.2},
		"cancel_startup": Cfg.CANCEL["NONE"],
		"cancel_active": Cfg.CANCEL["HIT"],
		"cancel_recovery": Cfg.CANCEL["HIT"],
		"move": {"startup": 1.6, "active": 0.6, "recovery": 0.0},
		"next": "", "chain": "", "gravity": false, "sfx": "swing_heavy",
	},
	"air_attack": {
		"startup": 5, "active": 6, "recovery": 10, "dmg": 12, "mult": 0,
		"box": {"ox": 12, "oy": -14, "w": 26, "h": 24},
		"hitstop": 4, "poise_dmg": 14, "kb": {"x": 2.4, "y": 1.0},
		"cancel_startup": Cfg.CANCEL["NONE"],
		"cancel_active": Cfg.CANCEL["HIT"],
		"cancel_recovery": Cfg.CANCEL["HIT"],
		"move": {"startup": 0.0, "active": 0.0, "recovery": 0.0},
		"next": "", "chain": "", "gravity": true, "sfx": "swing_light",
	},
	"plunge": {
		"startup": 4, "active": 999, "recovery": 14, "dmg": 20, "mult": 0,
		"box": {"ox": 0, "oy": -14, "w": 30, "h": 28},
		"hitstop": 6, "poise_dmg": 26, "kb": {"x": 1.0, "y": -4.0},
		"cancel_startup": Cfg.CANCEL["NONE"],
		"cancel_active": Cfg.CANCEL["NONE"],
		"cancel_recovery": Cfg.CANCEL["HIT"],
		"move": {"startup": 0.0, "active": 0.0, "recovery": 0.0},
		"next": "", "chain": "", "gravity": true, "sfx": "swing_heavy",
	},
	"roll": {
		"startup": 3, "active": 0, "recovery": 14, "dmg": 0, "mult": 0,
		"box": {"ox": 0, "oy": 0, "w": 0, "h": 0},
		"hitstop": 0, "poise_dmg": 0, "kb": {"x": 0, "y": 0},
		"cancel_startup": Cfg.CANCEL["NONE"],
		"cancel_active": Cfg.CANCEL["NONE"],
		"cancel_recovery": Cfg.CANCEL["WHIFF"] | Cfg.CANCEL["KARA"],
		"move": {"startup": 6.2, "active": 6.2, "recovery": 0.0},
		"next": "", "chain": "", "gravity": false, "sfx": "roll",
		"invuln": [3, 12],          # 翻滚无敌帧（帧区间，闭区间）
	},
	"dash": {
		"startup": 2, "active": 6, "recovery": 8, "dmg": 0, "mult": 0,
		"box": {"ox": 0, "oy": 0, "w": 0, "h": 0},
		"hitstop": 0, "poise_dmg": 0, "kb": {"x": 0, "y": 0},
		"cancel_startup": Cfg.CANCEL["NONE"],
		"cancel_active": Cfg.CANCEL["NONE"],
		"cancel_recovery": Cfg.CANCEL["WHIFF"] | Cfg.CANCEL["KARA"],
		"move": {"startup": 7.0, "active": 7.0, "recovery": 0.0},
		"next": "", "chain": "", "gravity": false, "sfx": "dash",
	},
	"block": {
		"startup": 2, "active": 0, "recovery": 6, "dmg": 0, "mult": 0,
		"box": {"ox": 0, "oy": 0, "w": 0, "h": 0},
		"hitstop": 0, "poise_dmg": 0, "kb": {"x": 0, "y": 0},
		"cancel_startup": Cfg.CANCEL["NONE"],
		"cancel_active": Cfg.CANCEL["NONE"],
		"cancel_recovery": Cfg.CANCEL["WHIFF"] | Cfg.CANCEL["BLOCK"],
		"move": {"startup": 0.0, "active": 0.0, "recovery": 0.0},
		"next": "", "chain": "", "gravity": false, "sfx": "block_up",
		"hold": true,               # 按住持续
	},
	"parry": {
		"startup": 2, "active": 0, "recovery": 8, "dmg": 0, "mult": 0,
		"box": {"ox": 0, "oy": 0, "w": 0, "h": 0},
		"hitstop": 0, "poise_dmg": 0, "kb": {"x": 0, "y": 0},
		"cancel_startup": Cfg.CANCEL["NONE"],
		"cancel_active": Cfg.CANCEL["NONE"],
		"cancel_recovery": Cfg.CANCEL["WHIFF"],
		"move": {"startup": 0.0, "active": 0.0, "recovery": 0.0},
		"next": "", "chain": "", "gravity": false, "sfx": "parry",
		"parry_frames": int(Cfg.FRAME["parry_window"]),
	},
	"parry_counter": {
		"startup": 4, "active": 5, "recovery": 16, "dmg": 26, "mult": 0,
		"box": {"ox": 15, "oy": -19, "w": 32, "h": 26},
		"hitstop": 10, "poise_dmg": 40, "kb": {"x": 5.5, "y": -4.0},
		"cancel_startup": Cfg.CANCEL["NONE"],
		"cancel_active": Cfg.CANCEL["HIT"],
		"cancel_recovery": Cfg.CANCEL["HIT"],
		"move": {"startup": 2.0, "active": 0.4, "recovery": 0.0},
		"next": "", "chain": "", "gravity": false, "sfx": "counter",
	},
	"heal": {
		"startup": 30, "active": 0, "recovery": 12, "dmg": 0, "mult": 0,
		"box": {"ox": 0, "oy": 0, "w": 0, "h": 0},
		"hitstop": 0, "poise_dmg": 0, "kb": {"x": 0, "y": 0},
		"cancel_startup": Cfg.CANCEL["NONE"],
		"cancel_active": Cfg.CANCEL["NONE"],
		"cancel_recovery": Cfg.CANCEL["NONE"],
		"move": {"startup": 0.0, "active": 0.0, "recovery": 0.0},
		"next": "", "chain": "", "gravity": false, "sfx": "heal",
		"hold": true,
	},
	"land": {
		"startup": 3, "active": 0, "recovery": 3, "dmg": 0, "mult": 0,
		"box": {"ox": 0, "oy": 0, "w": 0, "h": 0},
		"hitstop": 0, "poise_dmg": 0, "kb": {"x": 0, "y": 0},
		"cancel_startup": Cfg.CANCEL["NONE"],
		"cancel_active": Cfg.CANCEL["NONE"],
		"cancel_recovery": Cfg.CANCEL["WHIFF"] | Cfg.CANCEL["KARA"],
		"move": {"startup": 0.0, "active": 0.0, "recovery": 0.0},
		"next": "", "chain": "", "gravity": false, "sfx": "land",
	},
	"hurt": {
		"startup": 0, "active": 0, "recovery": int(Cfg.FRAME["hitstun_light"]), "dmg": 0, "mult": 0,
		"box": {"ox": 0, "oy": 0, "w": 0, "h": 0},
		"hitstop": 0, "poise_dmg": 0, "kb": {"x": 0, "y": 0},
		"cancel_startup": Cfg.CANCEL["NONE"], "cancel_active": Cfg.CANCEL["NONE"],
		"cancel_recovery": Cfg.CANCEL["NONE"],
		"move": {"startup": 0.0, "active": 0.0, "recovery": 0.0},
		"next": "", "chain": "", "gravity": false, "sfx": "",
	},
	"getup": {
		"startup": 0, "active": 0, "recovery": 22, "dmg": 0, "mult": 0,
		"box": {"ox": 0, "oy": 0, "w": 0, "h": 0},
		"hitstop": 0, "poise_dmg": 0, "kb": {"x": 0, "y": 0},
		"cancel_startup": Cfg.CANCEL["NONE"], "cancel_active": Cfg.CANCEL["NONE"],
		"cancel_recovery": Cfg.CANCEL["NONE"],
		"move": {"startup": 0.0, "active": 0.0, "recovery": 0.0},
		"next": "", "chain": "", "gravity": false, "sfx": "",
	},
}

# --------------------------------------------------------------------------
# 敌人数据（八类原型 + Boss）
# --------------------------------------------------------------------------
# telegraph_startup = 预警帧数：这是**公平性的硬指标**（§7.1）
# 每一种攻击都必须能被反应：预警帧数 >= 反应时间 + 帧数据的起手帧。
const ENEMIES := {
	"rusher": {
		"hp": 22, "dmg": 6, "speed": 96.0, "weight": "light",
		"poise": 12, "attack_range": 22.0, "keep_dist": 0.0,
		"telegraph": 16, "startup": 6, "active": 5, "recovery": 16,
		"box": {"ox": 11, "oy": -18, "w": 20, "h": 20},
		"kb": {"x": 3.2, "y": -1.4}, "hitstop": 3, "poise_dmg": 10,
		"can_chase_air": false, "boss": false, "solution": "翻滚穿过（它的冲刺是直线）",
	},
	"shielded": {
		"hp": 34, "dmg": 8, "speed": 62.0, "weight": "medium",
		"poise": 24, "attack_range": 24.0, "keep_dist": 0.0,
		"telegraph": 22, "startup": 9, "active": 5, "recovery": 22,
		"box": {"ox": 13, "oy": -18, "w": 24, "h": 22},
		"kb": {"x": 3.6, "y": -1.6}, "hitstop": 4, "poise_dmg": 14,
		"guard": true,              # 正面减伤 80%，破韧或背刺才吃满
		"can_chase_air": false, "boss": false, "solution": "削韧破防 / 绕背",
	},
	"archer": {
		"hp": 18, "dmg": 5, "speed": 52.0, "weight": "light",
		"poise": 10, "attack_range": 190.0, "keep_dist": 120.0,
		"telegraph": 26, "startup": 12, "active": 0, "recovery": 26,
		"box": {"ox": 0, "oy": 0, "w": 0, "h": 0}, "ranged": true,
		"projectile": {"speed": 200.0, "dmg": 5, "gravity": 90.0, "life": 200},
		"kb": {"x": 0, "y": 0}, "hitstop": 0, "poise_dmg": 0,
		"can_chase_air": false, "boss": false, "solution": "贴身 / 格挡箭矢",
	},
	"caster": {
		"hp": 26, "dmg": 7, "speed": 44.0, "weight": "light",
		"poise": 12, "attack_range": 170.0, "keep_dist": 110.0,
		"telegraph": 34, "startup": 16, "active": 0, "recovery": 34,
		"box": {"ox": 0, "oy": 0, "w": 0, "h": 0}, "ranged": true,
		"projectile": {"speed": 130.0, "dmg": 7, "gravity": 0.0, "life": 260, "homing": 0.35},
		"kb": {"x": 0, "y": 0}, "hitstop": 0, "poise_dmg": 0,
		"can_chase_air": false, "boss": false, "solution": "优先爆发秒掉",
	},
	"exploder": {
		"hp": 16, "dmg": 14, "speed": 108.0, "weight": "light",
		"poise": 8, "attack_range": 26.0, "keep_dist": 0.0,
		"telegraph": 20, "startup": 4, "active": 8, "recovery": 20,
		"box": {"ox": 0, "oy": -20, "w": 44, "h": 40}, "suicide": true,
		"kb": {"x": 6.0, "y": -5.0}, "hitstop": 6, "poise_dmg": 24,
		"can_chase_air": false, "boss": false, "solution": "拉开距离或用击退引爆",
	},
	"flyer": {
		"hp": 20, "dmg": 6, "speed": 74.0, "weight": "light",
		"poise": 10, "attack_range": 24.0, "keep_dist": 0.0,
		"telegraph": 18, "startup": 6, "active": 5, "recovery": 18,
		"box": {"ox": 10, "oy": -16, "w": 22, "h": 20},
		"kb": {"x": 2.8, "y": -1.2}, "hitstop": 3, "poise_dmg": 10,
		"flying": true, "fly_height": 76.0, "can_chase_air": true, "boss": false,
		"solution": "打空 / 等它扑下来",
	},
	"brute": {
		"hp": 70, "dmg": 12, "speed": 54.0, "weight": "heavy",
		"poise": 46, "attack_range": 30.0, "keep_dist": 0.0,
		"telegraph": 40, "startup": 18, "active": 6, "recovery": 34,
		"box": {"ox": 15, "oy": -20, "w": 32, "h": 30},
		"kb": {"x": 5.6, "y": -3.0}, "hitstop": 6, "poise_dmg": 30,
		"super_armor": true,        # 起手后不吃轻击硬直
		"can_chase_air": false, "boss": false, "solution": "卡身位 + 弹反",
	},
	"summoner": {
		"hp": 30, "dmg": 6, "speed": 46.0, "weight": "medium",
		"poise": 18, "attack_range": 150.0, "keep_dist": 100.0,
		"telegraph": 30, "startup": 14, "active": 0, "recovery": 30,
		"box": {"ox": 0, "oy": 0, "w": 0, "h": 0}, "ranged": true,
		"projectile": {"speed": 120.0, "dmg": 6, "gravity": 0.0, "life": 240},
		"summon": {"archetype": "rusher", "count": 1, "cap": 3, "cooldown": 300},
		"kb": {"x": 0, "y": 0}, "hitstop": 0, "poise_dmg": 0,
		"can_chase_air": false, "boss": false, "solution": "速杀，别让它滚雪球",
	},
}

## Boss = brute 的强化版（同一套状态机，换数值 + 更多招式槽）
const BOSS := {
	"hp": 420, "dmg": 18, "speed": 60.0, "weight": "boss",
	"poise": 120, "attack_range": 40.0, "keep_dist": 0.0,
	"telegraph": 44, "startup": 20, "active": 7, "recovery": 36,
	"box": {"ox": 18, "oy": -24, "w": 40, "h": 34},
	"kb": {"x": 6.0, "y": -3.4}, "hitstop": 6, "poise_dmg": 34,
	"super_armor": true, "boss": true,
	"projectile": {"speed": 150.0, "dmg": 12, "gravity": 60.0, "life": 220},
	"summon": {"archetype": "rusher", "count": 2, "cap": 4, "cooldown": 420},
	"can_chase_air": false, "solution": "分阶段：进身 → 弹反 → 惩罚硬直",
}

# --------------------------------------------------------------------------
# 难度契约（§4.3）：血量指数增长、伤害线性且慢得多
# --------------------------------------------------------------------------

static func hp_scale(floor_index: int) -> float:
	return pow(1.0 + float(Cfg.DIFFICULTY["hp_per_floor"]), float(floor_index - 1))

static func dmg_scale(floor_index: int) -> float:
	var per: float = float(Cfg.DIFFICULTY["dmg_per_floor"]) * float(Cfg.DIFFICULTY["dmg_gain"])
	return pow(1.0 + per, float(floor_index - 1))

static func enemy_stats(archetype: String, floor_index: int, elite: bool) -> Dictionary:
	var base: Dictionary = BOSS if archetype == "boss" else ENEMIES.get(archetype, ENEMIES["rusher"])
	var d: Dictionary = base.duplicate(true)
	d["hp"] = int(round(float(base["hp"]) * hp_scale(floor_index) * (1.6 if elite else 1.0)))
	d["dmg"] = int(round(float(base["dmg"]) * dmg_scale(floor_index) * (1.15 if elite else 1.0)))
	d["poise"] = int(round(float(base["poise"]) * (1.4 if elite else 1.0)))
	d["archetype"] = archetype
	return d

# --------------------------------------------------------------------------
# 伤害公式（§6.2）
# --------------------------------------------------------------------------

## 连段倍率：第 n 段（0 起）按 combo_mult 表，之后按衰减。
static func combo_mult(chain_index: int) -> float:
	var tbl: Array = Cfg.DMG["combo_mult"]
	if chain_index < tbl.size():
		return float(tbl[chain_index])
	# 连段 >= hitstun_decay_combo 段开始衰减，避免无限连
	var decay_start: int = int(Cfg.FRAME["hitstun_decay_combo"])
	if chain_index < decay_start:
		return float(tbl[tbl.size() - 1])
	return maxf(0.35, float(tbl[tbl.size() - 1]) * pow(0.88, float(chain_index - decay_start)))

## 削韧：stagger_base + 目标 poise * 0.5，再乘招式削韧
static func stagger_amount(move_poise_dmg: int, target_poise: int) -> float:
	return float(move_poise_dmg) * (1.0 + float(target_poise) * float(Cfg.DMG["stagger_per_poise"]) / 100.0)

## 击退抗性：体重越重击退越弱
static func knockback_scale(weight: String) -> float:
	match weight:
		"light":
			return 1.0
		"medium":
			return 0.72
		"heavy":
			return 0.45
		"boss":
			return 0.20
		_:
			return 1.0

## 玩家对敌人：伤害 = 基础 × 连段倍率 × 稀有度强度
static func player_damage(move: Dictionary, chain_index: int, power: float,
						  stagger_bonus: bool) -> int:
	var d: float = float(move["dmg"])
	d *= combo_mult(chain_index)
	d *= power
	if stagger_bonus:
		d *= float(Cfg.DMG["stagger_dmg_mult"])
	return maxi(1, int(round(d)))
