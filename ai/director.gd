# Director —— AI 导演层（上下文 / 受限原语 / 校验器 / 双缓冲 / 降级）
#
# 一句话：**模型是脑子，不是手。**
# 模型读一个 6 维 ctx，写一条受限原语；原语先过确定性校验器，再异步双缓冲生效。
# 玩家在整条链路上**感觉不到**模型的存在或缺失 —— 因为默认档（L1 规则脑）
# 本来就是完整可玩的，模型只是把它替换成更有风格的版本。
#
# 三档降级（永远不在关键路径上）：
#   L2 模型脑：模型可用且返回合法原语 → 用它
#   L1 规则脑：超时/非法/未配置 → 本地规则（默认档）
#   L0 冻结：连续 N 次失败 → 冻结最近一次合法 ctx，本局不再查询
#
# 铁律（代码里硬编码，不信提示词）：
#   铁律 A 低血不后退：玩家 hp < 30% 时 aggression 不得上升、不得追加敌人。
#   铁律 B 怜悯有窗口：mercy 只在「低血 + 3 秒没受伤 + 敌人 <= 2」时才允许生效。
#   铁律 C 原语白名单：不在表里的原语整条丢弃（不是部分生效）。
#   铁律 D 影子模式：只记录不生效，用来回答「模型到底做了什么」。

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const BT = preload("res://ai/bt.gd")
const Dig = preload("res://core/digest.gd")

# --------------------------------------------------------------------------
# 原语白名单
# --------------------------------------------------------------------------

const PRIMITIVES := {
	"set_ctx":       {"args": ["dim", "value"], "dim_enum": "CTX_KEYS"},
	"spawn_wave":    {"args": ["archetype", "count", "delay_frames"],
					  "ranges": {"count": [1, 3], "delay_frames": [0, 180]}},
	"set_pacing":    {"args": ["room_interval_frames"], "ranges": {"room_interval_frames": [60, 600]}},
	"grant_pickup":  {"args": ["kind", "rarity_delta"], "ranges": {"rarity_delta": [-1, 1]}},
	"set_affix":     {"args": ["affix", "elite_only"]},
	"hint":          {"args": ["text_id"], "id_whitelist": true},
	"noop":          {"args": []},
}

## 允许给玩家看的提示（自然语言出口只有这一个，且只能选 id）
const HINTS := {
	"careful": "前面有埋伏。",
	"rest":    "这里安全，喘口气。",
	"elite":   "重甲在前 —— 削韧或绕背。",
	"low_hp":  "血不多了，考虑后撤。",
	"secret":  "这房间有夹层。",
}

# --------------------------------------------------------------------------
# 上下文
# --------------------------------------------------------------------------

## 从运行态统计出 6 维 ctx。**这是模型看到的全部世界。**
static func build_ctx(level, stats: Dictionary) -> Dictionary:
	var hp: float = float(stats["hp_ratio"])
	var alive: int = int(stats["alive"])
	var agg: float = 0.35 + 0.5 * clampf(1.0 - hp, 0.0, 1.0) * 0.0   # 由规则脑覆盖
	var dealt: int = int(stats["dealt"])
	var taken: int = int(stats["taken"])
	# 规则脑的默认值：玩家打得顺 → 加压；玩家挨打多 → 减压
	var pressure: float = clampf(0.5 + float(dealt - taken) / 240.0, 0.15, 0.95)
	var ctx := {
		"aggression": pressure,
		"defense": clampf(0.6 - pressure * 0.3, 0.15, 0.9),
		"range_target": 0.45,
		"rhythm": clampf(0.35 + 0.5 * (1.0 - hp), 0.2, 0.9),
		"focus": clampf(0.4 + 0.05 * float(alive), 0.2, 0.9),
		"mercy": clampf((0.35 - hp) / 0.35 * 0.8, 0.0, 0.8),
	}
	return clamp_ctx(ctx, level)

## 铁律 A / B 在**所有** ctx（不管来自规则脑还是模型）上强制执行。
static func clamp_ctx(ctx: Dictionary, level) -> Dictionary:
	var out := ctx.duplicate()
	for k in Cfg.CTX_KEYS:
		out[k] = clampf(float(out.get(k, 0.5)), 0.0, 1.0)
	if level != null and level.player != null:
		var hp: float = float(level.player.hp) / float(maxi(1, level.player.max_hp))
		if hp < 0.30:
			# 铁律 A：低血不后退 —— 进攻性不得上升
			out["aggression"] = minf(float(out["aggression"]), 0.45)
			out["rhythm"] = minf(float(out["rhythm"]), 0.5)
		# 铁律 B：怜悯只在窗口内
		var recent_hurt: bool = level.player.invuln > 0 or _took_damage_recently(level, 180)
		var few: bool = _alive_enemies(level) <= 2
		if not (hp < 0.35 and not recent_hurt and few):
			out["mercy"] = 0.0
	return out

static func _took_damage_recently(level, win: int) -> bool:
	for e in level.events:
		if e.kind == "enemy_hit" and e.frame > level.frame - win:
			return true
	return false

static func _alive_enemies(level) -> int:
	var n := 0
	for a in level.actors:
		if a.kind == "enemy" and a.alive:
			n += 1
	return n

# --------------------------------------------------------------------------
# 校验器：模型与游戏之间的最后一道门
# --------------------------------------------------------------------------

static func validate(prims: Array, level, ctx: Dictionary, used: Dictionary) -> Dictionary:
	var accepted: Array = []
	var rejects: Array = []
	for pr in prims:
		var name: String = str(pr.get("prim", ""))
		if not PRIMITIVES.has(name):
			rejects.append({"prim": name, "why": "白名单外"})
			continue
		var spec: Dictionary = PRIMITIVES[name]
		# 参数范围
		var bad := ""
		for arg in spec["args"]:
			if not pr.has(arg):
				bad = "缺参数 %s" % arg
				break
		if bad != "":
			rejects.append({"prim": name, "why": bad})
			continue
		if name == "set_ctx":
			var dim: String = str(pr["dim"])
			if not (dim in Cfg.CTX_KEYS):
				rejects.append({"prim": name, "why": "非 ctx 维 %s" % dim})
				continue
			if float(pr["value"]) < 0.0 or float(pr["value"]) > 1.0:
				rejects.append({"prim": name, "why": "值越界"})
				continue
		elif spec.has("ranges"):
			var ranges: Dictionary = spec["ranges"]
			var oob := ""
			for arg2 in ranges.keys():
				var r: Array = ranges[arg2]
				if float(pr[arg2]) < float(r[0]) or float(pr[arg2]) > float(r[1]):
					oob = "%s=%s 越界 [%s,%s]" % [arg2, str(pr[arg2]), str(r[0]), str(r[1])]
					break
			if oob != "":
				rejects.append({"prim": name, "why": oob})
				continue
		elif name == "hint":
			if not HINTS.has(str(pr["text_id"])):
				rejects.append({"prim": name, "why": "非白名单提示 id"})
				continue
		elif name == "set_affix":
			if not Cfg.AFFIXES.has(str(pr["affix"])):
				rejects.append({"prim": name, "why": "未知词缀"})
				continue
		# 铁律 A：低血期间禁止加码
		if level != null and level.player != null:
			var hp: float = float(level.player.hp) / float(maxi(1, level.player.max_hp))
			if hp < 0.30:
				if name == "spawn_wave":
					rejects.append({"prim": name, "why": "铁律A 低血不加援军"})
					continue
				if name == "set_ctx" and str(pr["dim"]) == "aggression" and float(pr["value"]) > 0.5:
					rejects.append({"prim": name, "why": "铁律A 低血不提升进攻性"})
					continue
		# 幂等：同房同原语不重复生效
		var sig := "%d|%s|%s" % [level.current_room if level != null else -1, name, str(pr)]
		if used.has(sig):
			rejects.append({"prim": name, "why": "同房重复"})
			continue
		used[sig] = true
		accepted.append(pr)
	return {"accept": accepted, "reject": rejects}

## 执行合法原语。返回事件日志（只读，供「AI 透明度」界面显示）。
static func apply(accepted: Array, level, ctx: Dictionary) -> Array:
	var log_out: Array = []
	for pr in accepted:
		var name: String = str(pr["prim"])
		match name:
			"set_ctx":
				ctx[str(pr["dim"])] = float(pr["value"])
				log_out.append("set_ctx(%s=%.2f)" % [pr["dim"], pr["value"]])
			"spawn_wave":
				var arch: String = str(pr["archetype"])
				var cnt: int = int(pr["count"])
				if arch == "boss":
					arch = "brute"
				level.spawn_enemy_for(level.player, arch, cnt, 6)
				log_out.append("spawn_wave(%s×%d)" % [arch, cnt])
			"set_pacing":
				level.pacing_frames = int(pr["room_interval_frames"])
				log_out.append("set_pacing(%d)" % pr["room_interval_frames"])
			"grant_pickup":
				level.loot_rarity_delta += int(pr["rarity_delta"])
				log_out.append("grant_pickup(%s,%+d)" % [pr["kind"], int(pr["rarity_delta"])])
			"set_affix":
				level.pending_affix = str(pr["affix"])
				log_out.append("set_affix(%s)" % pr["affix"])
			"hint":
				level.hint_text = str(HINTS[str(pr["text_id"])])
				log_out.append("hint(%s)" % pr["text_id"])
			"noop":
				log_out.append("noop")
	return log_out

# --------------------------------------------------------------------------
# L1 规则脑（默认档：没有模型也完整可玩）
# --------------------------------------------------------------------------

class RuleBrain:
	var period: int = 240

	func decide(level, ctx: Dictionary, stats: Dictionary) -> Array:
		var out: Array = []
		var hp: float = float(stats["hp_ratio"])
		var alive: int = int(stats["alive"])
		# 玩家顺 → 加压；玩家挨打 → 减压；这是「节奏编辑器」而不是「难度作弊」
		if hp > 0.6 and alive == 0:
			out.append({"prim": "set_ctx", "dim": "aggression", "value": 0.72})
			out.append({"prim": "set_ctx", "dim": "rhythm", "value": 0.62})
		elif hp < 0.4:
			out.append({"prim": "set_ctx", "dim": "aggression", "value": 0.4})
			out.append({"prim": "set_ctx", "dim": "mercy", "value": 0.6})
		else:
			out.append({"prim": "set_ctx", "dim": "aggression", "value": 0.55})
		if alive >= 5:
			out.append({"prim": "set_ctx", "dim": "focus", "value": 0.3})
		if str(stats.get("room_type", "")) == "elite":
			out.append({"prim": "hint", "text_id": "elite"})
		out.append({"prim": "noop"})
		return out

# --------------------------------------------------------------------------
# L2 模型脑（本机 OpenAI 兼容端点；没有就自动降级）
# --------------------------------------------------------------------------

class ModelBrain:
	var url: String = "http://127.0.0.1:8080/v1/chat/completions"
	var model: String = "local-small"
	var timeout_s: float = 2.0
	var last_error: String = ""

	## 提示词把「能做什么」写成**枚举**，而不是自然语言自由发挥。
	## 这是把模型关进笼子的第一层（第二层是校验器，第三层是铁律）。
	func make_prompt(level, ctx: Dictionary, stats: Dictionary) -> String:
		var allowed: Array = []
		for k in PRIMITIVES.keys():
			allowed.append(k)
		var lines: Array = []
		lines.append("你是 2D 横板动作 roguelike 的关卡导演。你只能输出 JSON 数组，每个元素形如 {\"prim\":\"set_ctx\",\"dim\":\"aggression\",\"value\":0.6}。")
		lines.append("允许的原语：%s" % ", ".join(allowed))
		lines.append("ctx 维度：%s（值域 0..1）" % ", ".join(Cfg.CTX_KEYS))
		lines.append("当前状态：hp=%.2f，房内敌人=%d，最近6秒输出=%d，受伤=%d，房型=%s，已无伤通过%d房。"
			% [float(stats["hp_ratio"]), int(stats["alive"]), int(stats["dealt"]),
			   int(stats["taken"]), str(stats["room_type"]), int(stats["clean_rooms"])])
		lines.append("铁律：玩家血量低于 30%% 时不得提升 aggression、不得 spawn_wave。")
		lines.append("目标：让节奏好看（该紧则紧、该喘则喘），而不是让玩家死。最多 3 条原语。")
		return "\n".join(lines)

	func request(level, ctx: Dictionary, stats: Dictionary) -> Array:
		last_error = ""
		var http := HTTPClient.new()
		var err := http.connect_to_host(_host(), _port())
		if err != OK:
			last_error = "connect %d" % err
			return []
		var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
		while http.get_status() == HTTPClient.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
			http.poll()
		if http.get_status() != HTTPClient.STATUS_CONNECTED:
			last_error = "no connection"
			return []
		var body := JSON.stringify({
			"model": model, "temperature": 0.4, "max_tokens": 200,
			"messages": [{"role": "user", "content": make_prompt(level, ctx, stats)}],
		})
		var headers := PackedStringArray(["Content-Type: application/json"])
		http.request(HTTPClient.METHOD_POST, "/v1/chat/completions", headers, body)
		while http.get_status() == HTTPClient.STATUS_REQUESTING and Time.get_ticks_msec() < deadline:
			http.poll()
		if not http.has_response():
			last_error = "no response"
			return []
		var rb := PackedByteArray()
		while http.get_status() == HTTPClient.STATUS_BODY and Time.get_ticks_msec() < deadline:
			http.poll()
			rb.append_array(http.read_response_body_chunk())
		var txt := rb.get_string_from_utf8()
		return parse_reply(txt)

	func _host() -> String:
		var s: String = url.replace("http://", "")
		var slash: int = s.find("/")
		if slash >= 0:
			s = s.substr(0, slash)
		var colon: int = s.find(":")
		return s.substr(0, colon) if colon >= 0 else s

	func _port() -> int:
		var s: String = url.replace("http://", "")
		var colon: int = s.find(":")
		if colon < 0:
			return 80
		var rest: String = s.substr(colon + 1)
		var slash: int = rest.find("/")
		if slash >= 0:
			rest = rest.substr(0, slash)
		return int(rest)

	## 解析：只认 JSON 数组；任何解析失败都返回空（= 降级到 L1）
	static func parse_reply(txt: String) -> Array:
		var start: int = txt.find("[")
		var end: int = txt.rfind("]")
		if start < 0 or end <= start:
			return []
		var arr = JSON.parse_string(txt.substr(start, end - start + 1))
		if typeof(arr) != TYPE_ARRAY:
			return []
		var out: Array = []
		for x in arr:
			if typeof(x) == TYPE_DICTIONARY and x.has("prim"):
				out.append(x)
			if out.size() >= 3:
				break
		return out

# --------------------------------------------------------------------------
# 导演本体：双缓冲 + 影子 + 降级 + 日志
# --------------------------------------------------------------------------

var level = null
var rule_brain = RuleBrain.new()
var model_brain = ModelBrain.new()
var _model_wanted: bool = false
var buf_cur: Dictionary = {}
var buf_next: Dictionary = {}
var pending: bool = false
var queries_this_room: int = 0
var last_query_room: int = -1
var shadow: bool = false
var enabled: bool = true
var fails: int = 0
var brain_level: String = "L1"
var journal: Array = []
var used_sigs: Dictionary = {}
var last_stats: Dictionary = {}

func _init(use_model: bool = false, p_shadow: bool = false) -> void:
	shadow = p_shadow
	enabled = true
	brain_level = "L1"
	_model_wanted = use_model

func model_wanted() -> bool:
	return _model_wanted

func set_model_backend(url: String) -> void:
	model_brain.url = url
	_model_wanted = true

## 当前生效的 ctx（双缓冲的「读」端：永远立即可用，所以模型再慢也不卡帧）
func active_ctx() -> Dictionary:
	return buf_cur

func on_room_enter(p_level, room_index: int) -> void:
	level = p_level
	if not enabled:
		return
	queries_this_room = 0
	last_query_room = room_index
	# 进入房间时用规则脑先给一份立即可用的 ctx（L1 永远在线）
	var stats: Dictionary = level.stats_window()
	last_stats = stats
	var base: Dictionary = build_ctx(level, stats)
	var prims: Array = rule_brain.decide(level, base, stats)
	var v: Dictionary = validate(prims, level, base, used_sigs)
	apply(v["accept"], level, base)
	buf_next = clamp_ctx(base, level)
	buf_cur = buf_next.duplicate()
	_journal("room_enter", room_index, base, v, "L1")
	# 有模型且允许时，异步请求一次（每房 <= 1 次）
	if _model_wanted and fails < 3:
		_request_async()

func tick(p_level) -> void:
	level = p_level
	if not enabled:
		return
	# 双缓冲 swap：上一轮的后台结果在这里生效（1 房延迟，玩家感知不到）
	if pending and buf_next != buf_cur and not shadow:
		buf_cur = buf_next.duplicate()
		pending = false

func _request_async() -> void:
	# demo 里同步调一次本地端点（超时 2 s，且只发生在进房那一帧之后）
	# 正式版应放到 Thread 里；这里保持「不引入线程竞争」的简单性，
	# 因为**关键路径上用的是 buf_cur，请求慢不影响本帧**。
	pending = true
	var stats: Dictionary = last_stats
	var prims: Array = []
	if model_brain != null:
		prims = model_brain.request(level, buf_cur, stats)
	if prims.is_empty():
		fails += 1
		brain_level = "L1"
		_journal("model_fail", last_query_room, buf_cur, {"why": model_brain.last_error}, "L1")
		if fails >= 3:
			brain_level = "L0"
			enabled = false
		return
	fails = 0
	brain_level = "L2"
	var ctx: Dictionary = buf_cur.duplicate()
	var v: Dictionary = validate(prims, level, ctx, used_sigs)
	apply(v["accept"], level, ctx)
	var clamped: Dictionary = clamp_ctx(ctx, level)
	# 影子模式：写进 next 但**不 swap**（要观察，不要生效）
	buf_next = clamped
	_journal("model_ok", last_query_room, clamped, v, "L2")

func _journal(kind: String, room: int, ctx: Dictionary, verdict, level_name: String) -> void:
	var line := "[ai] t=%d room=%d brain=%s kind=%s ctx=%s verdict=%s" % [
		level.frame if level != null else -1, room, level_name, kind, _ctx_str(ctx), str(verdict)]
	journal.append(line)
	if journal.size() > 500:
		journal = journal.slice(journal.size() - 400, journal.size())
	level.log_event("ai", {"brain": level_name, "kind": kind, "room": room})

static func _ctx_str(ctx: Dictionary) -> String:
	var parts: Array = []
	for k in Cfg.CTX_KEYS:
		parts.append("%s=%.2f" % [k, float(ctx.get(k, 0.0))])
	return "{" + " ".join(parts) + "}"
