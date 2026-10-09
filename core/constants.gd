# Cfg —— 全局数值唯一真相（single source of truth）
#
# 铁律（机制拆解 §4 / 地图方案 §6.3）：
#   * 所有战斗数值以「整数帧」为单位书写，60 Hz 固定；
#   * 所有可达性常量**由物理参数推导**，禁止在生成器里再写一份魔数；
#   * 坐标用整型定点：1 px = SCALE 单位（沿用 Sakuga 内核的 SimulationScale）。
#
# 本文件是**纯常量/纯函数**，无状态、无副作用，可以被任何模块 preload。

extends RefCounted

# --------------------------------------------------------------------------
# 0. 版本与规格
# --------------------------------------------------------------------------

## 版本键：生成逻辑或模型权重一变即升，参与世界线编号与指纹。
const VERSION_KEY := "dsh-rl-v0.1"

## 生成器内部指纹用规格键（与 VERSION_KEY 分开：这里只描述生成算法结构）。
const GEN_SPEC_KEY := "gen-v1"

# --------------------------------------------------------------------------
# 1. 定点与时间
# --------------------------------------------------------------------------

## 定点缩放：1 px = 10000 单位（与 Sakuga-Engine SimulationScale 一致）。
const SCALE := 10000

## 逻辑帧率（唯一时钟；渲染与逻辑解耦）。
const FPS := 60

## 物理子步（等效 120 Hz 亚帧碰撞）。
const SUB_STEPS := 2

# --------------------------------------------------------------------------
# 2. 角色物理（跳跃运动学的唯一出处）
# --------------------------------------------------------------------------

const PHY := {
	"v0": 700.0,                  # 起跳初速 px/s（向上）
	"gravity": 2000.0,            # 重力 px/s^2
	"vx_run": 240.0,              # 地面最大水平速度
	"vx_dash": 420.0,             # 冲刺 / 跳跃水平速度（射程按此计）
	"vx_air_accel": 2600.0,       # 空中水平加速度
	"double_jump": true,
	"double_jump_factor": 0.8,    # 二段跳冲量 = factor * v0
	"fall_max": 300.0,            # 安全下落高度（超出需伤害区/回退）
	"tile": 16,                   # 格子尺寸 px
	"body_hw": 6.0,               # 角色水平半宽 px（12 px 宽）
	"body_h": 28.0,               # 角色身高 px
}

## 跳跃物理派生常量（由 PHY 推导；生成器只能读这里，不能自己写数）。
## h_single = v0^2/(2g)             = 122.5 px
## h_max    = h_single*(1 + k^2)    = 200.9 px
## t_air(flat) = v0/g               = 0.35 s
static func h_single() -> float:
	return PHY["v0"] * PHY["v0"] / (2.0 * PHY["gravity"])

static func h_max() -> float:
	var h: float = h_single()
	if PHY["double_jump"]:
		var v2: float = PHY["double_jump_factor"] * PHY["v0"]
		h += v2 * v2 / (2.0 * PHY["gravity"])
	return h

# --------------------------------------------------------------------------
# 3. 运动核（motion kernel）编译参数
# --------------------------------------------------------------------------

const KERNEL := {
	"max_rise": 208,        # 核覆盖的最大上跳高度 px（须 >= h_max）
	"max_fall": 304,        # 核覆盖的最大下落深度 px（须 >= fall_max）
	"step_height": 16,      # 这个高度以内算「走上台阶」
	"d": 4,                 # 水平加密步长 px
	"dh_step": 4,           # 高差步长 px
	"safety": 0.75,         # 难度旋钮：只使用射程的 safety 倍
	"landing_margin": 16.0,  # 落地余量 px
	"traj_bulge": 2,
	"forward_range": 12,    # 向前枚举的最大格数
}

# --------------------------------------------------------------------------
# 4. 帧手感常量（机制拆解 §4.1 / §5 / §6）
# --------------------------------------------------------------------------

const FRAME := {
	"input_buffer": 6,          # 输入缓冲帧
	"coyote": 6,                # 土狼时间
	"jump_buffer": 6,
	"hurt_invuln": 30,          # 受伤后无敌帧（防连锁锁死）
	"hitstun_light": 12,
	"hitstun_heavy": 18,
	"poise_player": 30,
	"guard_crush_stun": 40,     # 格挡破防硬直
	"parry_window": 6,          # 精准格挡窗口
	"parry_counter_stun": 18,   # 弹反成功后的反击硬直
	"block_damage_mult": 0.20,  # 格挡减伤 80%
	"combo_input_window": 12,   # 连段输入窗口（宽于取消窗口的部分由帧数据定）
	"kara_cancel_window": 3,    # 空振取消窗口（Sakuga 实测值）
	"min_hitstun": 8,
	"guard_crush_hitstun": 40,
	"hitstun_decay_combo": 8,   # 连段 >= 8 段开始衰减
}

## 玩家动作状态全集（§5.1）。同帧唯一状态。
const PLAYER_STATES: PackedStringArray = [
	"idle", "run", "jump", "fall", "land", "roll",
	"attack1", "attack2", "attack3", "air_attack", "plunge",
	"block", "parry", "parry_counter", "hurt", "launched", "down",
	"getup", "heal", "dead", "door_enter", "wall_slide", "dash",
]

## 取消权限位掩码（Sakuga 的 4 bit 取消系统，§附录 C.4）。
## 用位掩码而不是 if：装备/词条改取消规则 = 改一个 bit，天然可组合。
const CANCEL := {
	"NONE": 0,
	"WHIFF": 1,     # 空振取消
	"HIT": 2,       # 命中取消
	"BLOCK": 4,     # 被防御取消
	"KARA": 8,      # 起手取消（进入状态后前 kara_cancel_window 帧）
	"DEFAULT_ON_ENTER": 1 | 8,   # WHIFF | KARA
}

# --------------------------------------------------------------------------
# 5. 伤害与反馈（§4.2 / §6.2）
# --------------------------------------------------------------------------

const DMG := {
	"combo_mult": [1.0, 1.05, 1.15],   # 第 1/2/3 段
	"crit_mult": 0.5,
	"stagger_dmg_mult": 1.25,
	"stagger_base": 20,
	"stagger_per_poise": 0.5,
	"hitstop_light": 3,
	"hitstop_heavy": 6,
	"hitstop_parry": 10,
	"hitstop_break": 12,
	"flash_frames": 2,
	"shake_light": 3.0,
	"shake_heavy": 6.0,
	"shake_decay": 0.35,
}

## 结算顺序铁律（不可换序，否则出现「格挡了却掉血」）：
##   判定 → 无敌/格挡检查 → 韧性 → 伤害 → hitstop → 击退 → 事件日志
const RESOLVE_ORDER: PackedStringArray = [
	"hit_detect", "immunity_block_check", "poise", "damage",
	"hitstop", "knockback", "event_log",
]

# --------------------------------------------------------------------------
# 6. 敌人（§7）
# --------------------------------------------------------------------------

## 八类原型 —— 每类一个唯一威胁语义。
const ARCHETYPES := {
	"rusher":   {"threat": 2, "hp": 22, "dmg": 6,  "weight": "light",  "solution": "roll_through"},
	"shielded": {"threat": 3, "hp": 34, "dmg": 8,  "weight": "medium", "solution": "break_poise_or_backstab"},
	"archer":   {"threat": 3, "hp": 18, "dmg": 5,  "weight": "light",  "solution": "close_in_or_block"},
	"caster":   {"threat": 4, "hp": 26, "dmg": 7,  "weight": "light",  "solution": "burst_first"},
	"exploder": {"threat": 2, "hp": 16, "dmg": 14, "weight": "light",  "solution": "spacing_or_kb_detonate"},
	"flyer":    {"threat": 3, "hp": 20, "dmg": 6,  "weight": "light",  "solution": "air_attack"},
	"brute":    {"threat": 5, "hp": 70, "dmg": 12, "weight": "heavy",  "solution": "position_and_parry"},
	"summoner": {"threat": 4, "hp": 30, "dmg": 6,  "weight": "medium", "solution": "kill_fast"},
	# BOSS：第 3 层（最后一层）的守关者。数值按"能打但不磨人"给：
	# 血量 ≈ 3 个 brute，伤害 ≈ 1.3 个 brute，靠**阶段**而不是靠血厚制造压力。
	"boss":     {"threat": 9, "hp": 240, "dmg": 16, "weight": "boss",   "solution": "pattern_reading"},
}

## 体型的韧性倍率（輕/中/重）。
const WEIGHT_POISE_MULT := {"light": 1.0, "medium": 1.4, "heavy": 2.2, "boss": 6.0}

## 精英词缀（§7.3）。约束：caster/summoner 不得同时吃「滚雪球」类词缀。
const AFFIXES := {
	"frenzied":   {"desc": "加速，伤害 -15%", "dmg_mult": 0.85, "speed_mult": 1.35, "forbidden_on": []},
	"explosive":  {"desc": "死亡爆炸（20 帧预警）", "dmg_mult": 1.0, "speed_mult": 1.0, "forbidden_on": []},
	"venomous":   {"desc": "留毒池", "dmg_mult": 1.0, "speed_mult": 1.0, "forbidden_on": []},
	"thorned":    {"desc": "反弹近战 1 点", "dmg_mult": 1.0, "speed_mult": 1.0, "forbidden_on": []},
	"warded":     {"desc": "周期性护盾", "dmg_mult": 1.0, "speed_mult": 1.0, "forbidden_on": []},
	"summoning":  {"desc": "低血召唤 1 只", "dmg_mult": 1.0, "speed_mult": 1.0,
				   "forbidden_on": ["caster", "summoner"]},
}

const ELITE_THREAT_MULT := 1.5

## 难度契约（§4.3）
const DIFFICULTY := {
	"hp_per_floor": 0.18,
	"dmg_per_floor": 0.06,
	"dmg_gain": 0.5,        # 敌人伤害增长远慢于血量增长
	"base_budget": 24,
	"budget_per_floor": 0.12,
	"threat_cap_base": 6,
	"threat_cap_per_floor": 2,
	"max_enemies_screen": 12,
	"ttk_normal": [1.5, 3.0],
	"ttk_elite": [4.0, 7.0],
	"ttk_boss": [45.0, 90.0],
}

# --------------------------------------------------------------------------
# 7. 生成层（§8 / 地图方案 §4.6）
# --------------------------------------------------------------------------

const GEN := {
	"room_min_w": 44,            # 房间宽度下限（格）：6 格门段 + 边框 + 间隔
	"door_floor_min_px": 96,     # 门段脚下连续平地最小值（= 6 格）
	"door_headroom": 2,          # 门段上方净空格数
	"frame": 1,                  # 房间四周实心边框格数
	"corridor_clearance": 2,     # 走廊上方永久留空格数
	"max_step": 1,               # 相邻列地面高差上限（不变量 B）
	"runway_min_px": 48,         # 起跳前助跑下限
	"platform_min_w": 2,         # 平台至少 2 格宽（1 格宽容错为 0）
	"safe_gap_flat": 125,        # 安全间距（留 15% 余量）
	"safe_gap_up2": 225,
	"safe_gap_down": 195,
}

## 房间类型与配额（构造式约束，§8.1）
const ROOM_TYPES: PackedStringArray = [
	"start", "normal", "elite", "treasure", "shop", "rest", "secret", "boss", "exit", "shaft",
]

const ROOM_QUOTA := {
	"shop": 1,      # 每层 <= 1
	"secret": 1,    # 每层 <= 1
	"elite": 2,     # 每层 <= 2
	"rest": 1,      # 每层末尾强制 1
}

## Demo 关卡规格：3 张图（楼层）× 11 房 = 33 房。
const RUN := {
	"floors": 3,
	"rooms_per_floor": 11,
	"boss_floors": [3],          # demo：末层必出 Boss（正式规则 floor % 5 == 0）
	"cells_floor_1": 0,
	"cell_per_elite": 2,
	"cell_per_boss": 5,
}

# --------------------------------------------------------------------------
# 8. θ 六维（§8.3）：局内冻结，只影响下一局
# --------------------------------------------------------------------------

const THETA_KEYS: PackedStringArray = [
	"difficulty", "combat_density", "exploration", "loot", "risk", "narrative",
]

const THETA_DEFAULT := {
	"difficulty": 50,
	"combat_density": 50,
	"exploration": 50,
	"loot": 50,
	"risk": 35,
	"narrative": 50,
}

## 主题（由 narrative 驱动）
const THEMES: PackedStringArray = ["crypt", "ice", "ember", "verdant", "void"]

# --------------------------------------------------------------------------
# 9. 掉落 / 构筑 / 合成（§10）
# --------------------------------------------------------------------------

const RARITY: PackedStringArray = ["common", "rare", "epic", "legendary"]
const RARITY_CURVE := [0.60, 0.28, 0.10, 0.02]
const RARITY_AFFIX_COUNT := {"common": 0, "rare": 1, "epic": 2, "legendary": 3}
const RARITY_POWER := {"common": 1.0, "rare": 1.18, "epic": 1.38, "legendary": 1.65}

const SLOTS: PackedStringArray = ["weapon_a", "weapon_b", "skill_1", "skill_2", "amulet"]
const WEAPON_SWAP_FRAMES := 8

## 变异三系（§10.3）：每系一条可玩 BD 底线。
const MUTATION_TREES: PackedStringArray = ["brutality", "tactics", "survival"]

# --------------------------------------------------------------------------
# 10. AI 导演层（§9）
# --------------------------------------------------------------------------

const AI := {
	"query_per_room": 1,          # 每房 <= 1 次模型查询
	"query_per_floor": 2,         # 每层 <= 2 次
	"infer_budget_ms": 40,        # 推理预算（超时用上一次 ctx）
	"max_drop_fps_delta": 2.0,    # 模型在线/离线 1% low FPS 差值红线
	"bt_frame_divisor": 4,        # 每帧最多推进 ceil(alive/4) 个 BT
	"ctx_dims": 6,                # aggression/defense/range_target/rhythm/focus/mercy
	"shadow_mode": true,          # 影子模式：只记录不生效
	"http_timeout_ms": 1200,
	"default_endpoint": "http://127.0.0.1:8080/v1/chat/completions",
}

## ctx 六维的合法区间（离散化后才参与生成，§9.5）。
const CTX_RANGE := {
	"aggression": [0, 100],
	"defense": [0, 100],
	"range_target": [0, 100],
	"rhythm": [0, 100],
	"focus": [0, 100],
	"mercy": [0, 100],
}

const CTX_KEYS: PackedStringArray = [
	"aggression", "defense", "range_target", "rhythm", "focus", "mercy",
]

# --------------------------------------------------------------------------
# 11. 工具
# --------------------------------------------------------------------------

static func clamp_int(v: int, lo: int, hi: int) -> int:
	return lo if v < lo else (hi if v > hi else v)

static func clamp01f(v: float) -> float:
	return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)

## px -> 定点单位
static func to_fixed(px: float) -> int:
	return int(round(px * float(SCALE)))

## 定点单位 -> px
static func to_px(units: int) -> float:
	return float(units) / float(SCALE)

## 命令行是否带 --quick（自检短扫描）。把所有来源拼起来判断，
## 免得 Godot 版本之间 --script 与 -- 的相对位置差异把开关吃掉。
static func has_quick_flag() -> bool:
	var all := " ".join(OS.get_cmdline_args()) + " " + " ".join(OS.get_cmdline_user_args())
	return all.contains("--quick")

## 命令行里的 --key=value 取值（自检/模拟器用）。
static func cmdline_value(key: String, fallback: String = "") -> String:
	var all := " ".join(OS.get_cmdline_args()) + " " + " ".join(OS.get_cmdline_user_args())
	var parts := all.split(" ")
	for p in parts:
		if p.begins_with(key + "="):
			return p.substr(key.length() + 1)
	return fallback
