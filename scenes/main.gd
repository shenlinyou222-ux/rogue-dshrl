# Main —— 场景装配 + 输入 + 相机 + HUD（全部在代码里建，场景文件只有一行）
#
# 为什么不用编辑器摆节点：
#   `scenes/main.tscn` 里只有一个根节点，其它全部 programmatic。
#   理由是这个 demo 要在**无头环境**里也能被 tools/sim.gd 直接驱动：
#   逻辑层（RunState/Level/Actor）完全不依赖场景树，场景只是它的一个「显示器」。
#   于是「同一个世界线，可以被人玩，也可以被机器人跑」，证据链是同一份代码。

extends Node2D

const Cfg = preload("res://core/constants.gd")
const RunState = preload("res://run/run_state.gd")
const Art = preload("res://render/art.gd")
const Items = preload("res://loot/items.gd")

const VIEW := Vector2(960, 540)
const EDGE := 24.0

var run = null
var level = null
var cam: Vector2 = Vector2.ZERO
var show_ai: bool = true
var show_map: bool = false
var show_help: bool = true
var seed64: int = 0
var use_model: bool = false
var toast: String = ""
var toast_t: int = 0
var hitstop_shake: float = 0.0
var last_kills: int = 0
var fps_avg: float = 60.0
var frame_count: int = 0

func _ready() -> void:
	_ensure_actions()
	Engine.physics_ticks_per_second = int(Cfg.FPS)
	seed64 = int(Cfg.cmdline_value("--seed", str(Time.get_unix_time_from_system())))
	use_model = Cfg.cmdline_value("--ai", "0") != "0"
	_new_run()
	toast_msg("种子 %d · %s" % [seed64, "模型导演 L2" if use_model else "规则导演 L1"])

## 兜底注册按键动作。
## 为什么必须兜底：project.godot 的 [input] 里漏了 dash/heal 两个动作，
## 而 `_collect_input` 每帧都会 query 它们 —— Godot 会对**每一次**查询刷
## 「The InputMap action "dash" doesn't exist」，把控制台刷满并拖慢帧率。
## 动作表以代码为准，缺什么补什么（缺动作不影响已有动作）。
func _ensure_actions() -> void:
	var defs := {
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"move_up": [KEY_W, KEY_UP],
		"move_down": [KEY_S, KEY_DOWN],
		"jump": [KEY_SPACE, KEY_K],
		"attack": [KEY_J, KEY_X],
		"roll": [KEY_L, KEY_C],
		"dash": [KEY_L, KEY_C],
		"block": [KEY_I, KEY_Z],
		"swap_weapon": [KEY_Q],
		"interact": [KEY_E],
		"heal": [KEY_F],
	}
	for a in defs.keys():
		if not InputMap.has_action(a):
			InputMap.add_action(a)
			for k in defs[a]:
				var ev := InputEventKey.new()
				ev.keycode = k
				InputMap.action_add_event(a, ev)

func _new_run() -> void:
	run = RunState.new(seed64, use_model)
	run.generate()
	run.start_floor(1)
	level = run.level
	cam = _cam_target()
	last_kills = 0

# --------------------------------------------------------------------------
# 输入
# --------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_N:
				show_ai = not show_ai
			KEY_M:
				show_map = not show_map
			KEY_H:
				show_help = not show_help
			KEY_R:
				seed64 = int(Time.get_unix_time_from_system())
				_new_run()
				toast_msg("重开 · 种子 %d" % seed64)

func _collect_input() -> Dictionary:
	var inp := {
		"left": Input.is_action_pressed("move_left"),
		"right": Input.is_action_pressed("move_right"),
		"up": Input.is_action_pressed("move_up"),
		"down": Input.is_action_pressed("move_down"),
		"block": Input.is_action_pressed("block"),
		"jump_press": Input.is_action_just_pressed("jump"),
		"jump_release": Input.is_action_just_released("jump"),
	}
	var pl = run.player
	if inp["jump_press"]:
		pl.jump_buf = int(Cfg.FRAME["jump_buffer"])
	for a in ["attack", "roll", "dash", "heal", "skill_1", "skill_2"]:
		if Input.is_action_just_pressed(a):
			pl.press(a)
	if Input.is_action_just_pressed("interact"):
		_interact()
	return inp

func _interact() -> void:
	# 合成炉：背包里两件同类型装备 → 合成一件高一档的（词条取并集）。
	# 这是需求里"后面会有武器合成"的**口子已经接上电**：规则在 loot/items.gd
	# （can_fuse / fuse 是纯函数，可直接被 AI 导演层当原语调用），
	# 这里只负责"玩家按 F 触发 + 说清楚为什么不能合"。
	if run.state == "playing" and level != null and level.player != null:
		var pl = level.player
		var inv: Array = pl.inventory
		for i in range(inv.size()):
			for j in range(i + 1, inv.size()):
				var a: Dictionary = inv[i]
				var b: Dictionary = inv[j]
				if str(a.get("kind", "")) != str(b.get("kind", "")):
					continue
				var chk: Dictionary = Items.can_fuse(a, b)
				if not bool(chk["ok"]) and str(chk["why"]).begins_with("词条互斥"):
					continue          # 互斥词条就是不该能合
				var merged: Dictionary = Items.fuse(a, b, level.frame)
				if merged.is_empty():
					continue
				var slot := ""
				for s in pl.equipped.keys():
					if pl.equipped[s] == a:
						slot = str(s)
				inv.remove_at(j)
				inv.remove_at(i)
				inv.append(merged)
				if slot != "":
					pl.equipped[slot] = merged
				toast_msg("合成：%s → %s" % [Items.describe(a), Items.describe(merged)])
				level.log_event("craft", {"id": merged.get("id", "?"), "rarity": int(merged.get("rarity", 0))})
				return
		toast_msg("没有可合成的材料（同类型两件）")
		return
	if run.state == "floor_clear":
		run.next_floor()
		level = run.level
		cam = _cam_target()
		toast_msg("进入第 %d 层" % run.floor_index)
	elif run.state == "dead" or run.state == "won":
		seed64 = int(Time.get_unix_time_from_system())
		_new_run()

# --------------------------------------------------------------------------
# 物理帧
# --------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	frame_count += 1
	fps_avg = lerpf(fps_avg, Engine.get_frames_per_second(), 0.02)
	if run == null:
		return
	if run.state == "playing":
		var inp := _collect_input()
		run.step(inp)
	if level != null and level.total_kills != last_kills:
		last_kills = level.total_kills
		hitstop_shake = 2.0
	# 相机：横向跟随 + 纵向贴地（房间高 34 格，需要纵向跟随）
	cam = cam.lerp(_cam_target(), 0.14)
	hitstop_shake = maxf(0.0, hitstop_shake - 0.35)
	if toast_t > 0:
		toast_t -= 1
	queue_redraw()

func _cam_target() -> Vector2:
	if level == null or run == null or run.player == null:
		return Vector2.ZERO
	var p: Vector2 = run.player.p
	var tx: float = p.x - VIEW.x * 0.5
	var ty: float = p.y - VIEW.y * 0.62
	tx = clampf(tx, 0.0, maxf(0.0, float(level.map.w * 16) - VIEW.x))
	ty = clampf(ty, 0.0, maxf(0.0, float(level.map.h * 16) - VIEW.y))
	return Vector2(tx, ty)

func toast_msg(s: String) -> void:
	toast = s
	toast_t = 200

# --------------------------------------------------------------------------
# 绘制
# --------------------------------------------------------------------------

func _draw() -> void:
	if level == null:
		return
	var theme_name: String = str(level.event.theme) if level.event != null else "crypt"
	var shake := Vector2(0, 0)
	if hitstop_shake > 0.0:
		shake = Vector2(randf_range(-hitstop_shake, hitstop_shake),
						randf_range(-hitstop_shake, hitstop_shake))
	var cam_eff: Vector2 = cam + shake
	var cam_rect := Rect2(cam_eff, VIEW)

	# 背景
	draw_rect(Rect2(Vector2.ZERO, VIEW), Art.theme(theme_name)["bg"])
	draw_set_transform(-cam_eff, 0.0, Vector2.ONE)
	Art.draw_map(self, level, cam_rect, theme_name)
	Art.draw_decor(self, level, cam_rect, theme_name)
	Art.draw_pickups(self, level)
	Art.draw_actors(self, level, cam_rect)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	_draw_hud(theme_name)
	if show_map:
		_draw_map_overlay()
	if run.state == "dead":
		_draw_center_text("你死了", "按 F 重新开始 · 细胞 +%d" % run.meta.cells)
	elif run.state == "won":
		_draw_center_text("通关！", "按 F 再来一局 · 细胞 %d" % run.meta.cells)
	elif run.state == "floor_clear":
		_draw_center_text("第 %d 层清空" % run.floor_index, "按 F 进入下一层")

func _draw_center_text(title: String, sub: String) -> void:
	var f := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, VIEW), Color(0, 0, 0, 0.55))
	draw_string(f, Vector2(VIEW.x * 0.5 - 120.0, VIEW.y * 0.45), title,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 32, Color(1, 1, 1))
	draw_string(f, Vector2(VIEW.x * 0.5 - 120.0, VIEW.y * 0.45 + 30.0), sub,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.85, 0.85, 0.9))

func _draw_hud(theme_name: String) -> void:
	var f := ThemeDB.fallback_font
	var pl = run.player
	# 生命
	var hpw: float = 220.0
	var hpr: float = float(pl.hp) / float(maxi(1, pl.max_hp))
	draw_rect(Rect2(16, 16, hpw, 14), Color(0, 0, 0, 0.55))
	draw_rect(Rect2(16, 16, hpw * hpr, 14), Color(0.80, 0.22, 0.24))
	draw_rect(Rect2(16, 16, hpw, 14), Color(1, 1, 1, 0.25), false, 1.0)
	draw_string(f, Vector2(20, 27), "%d/%d" % [pl.hp, pl.max_hp], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1))
	# 耐力
	var sr: float = pl.stamina / maxf(1.0, pl.stamina_max)
	draw_rect(Rect2(16, 34, hpw, 8), Color(0, 0, 0, 0.5))
	draw_rect(Rect2(16, 34, hpw * sr, 8), Color(0.35, 0.75, 0.95))
	# 药瓶 / 碎片
	draw_string(f, Vector2(16, 60), "药 ×%d   碎片 %d   " % [pl.heal_flask, pl.money],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.9, 0.9, 0.95))
	# 层级 / 房型
	var room_type: String = str(level.rooms[level.current_room].rtype) if level.current_room < level.rooms.size() else "?"
	var info := "第 %d/%d 层 · 房 %d/%d(%s) · 事件: %s" % [
		run.floor_index, int(Cfg.RUN["floors"]), level.current_room + 1, level.rooms.size(),
		_room_cn(room_type), str(level.event.theme) if level.event != null else "-"]
	draw_string(f, Vector2(16, 78), info, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.8, 0.85, 0.9))
	if level.event != null and str(level.event.curse) != "":
		draw_string(f, Vector2(16, 94), "诅咒: %s" % str(level.event.curse),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.95, 0.7, 0.5))
	# 连段
	if pl.combo_count > 1:
		draw_string(f, Vector2(VIEW.x - 120, 40), "%d COMBO" % pl.combo_count,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1.0, 0.85, 0.4))
	# 装备
	var eq: String = ""
	for slot in ["weapon_a", "weapon_b", "amulet"]:
		if pl.equipped.has(slot):
			eq += "%s: %s   " % [slot, Items.describe(pl.equipped[slot])]
	if eq != "":
		draw_string(f, Vector2(16, VIEW.y - 18), eq, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.9, 1.0))
	# Boss 血条
	for a in level.actors:
		if a.kind == "enemy" and a.alive and (a.archetype == "boss"):
			var w: float = VIEW.x - 160.0
			var r: float = float(a.hp) / float(maxi(1, a.max_hp))
			draw_rect(Rect2(80, VIEW.y - 60, w, 12), Color(0, 0, 0, 0.6))
			draw_rect(Rect2(80, VIEW.y - 60, w * r, 12), Color(0.85, 0.25, 0.35))
			draw_string(f, Vector2(84, VIEW.y - 64), "BOSS", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1))
	# 提示
	if level.hint_text != "":
		draw_string(f, Vector2(VIEW.x * 0.5 - 90.0, 120), level.hint_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.95, 0.95, 0.6))
	# AI 日志（透明度：玩家可以关，也可以看）
	if show_ai and run.director != null:
		var j: Array = run.director.journal
		var n: int = mini(8, j.size())
		for i in range(n):
			var line: String = str(j[j.size() - n + i])
			draw_string(f, Vector2(VIEW.x - 470, 130 + i * 14), line.substr(0, 92),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.65, 0.85, 0.75, 0.9))
	# 帧时间（这是「模型不在关键路径上」的证据：开关 AI 前后帧时间应当无差别）
	draw_string(f, Vector2(VIEW.x - 130, VIEW.y - 18), "%.0f fps  frame %d" % [fps_avg, level.frame],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.7, 0.7))
	if show_help:
		draw_string(f, Vector2(VIEW.x - 300, VIEW.y - 34),
			"A/D 移动 空格 跳 J 攻击 K 翻滚 L 格挡 U/I 技能 F 交互",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.55, 0.6, 0.65))
		draw_string(f, Vector2(VIEW.x - 300, VIEW.y - 20),
			"N AI日志  M 地图  H 帮助  R 重开",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.55, 0.6, 0.65))
	if toast_t > 0:
		draw_string(f, Vector2(VIEW.x * 0.5 - 110.0, VIEW.y - 90), toast,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 0.8, minf(1.0, float(toast_t) / 60.0)))

func _room_cn(t: String) -> String:
	match t:
		"start": return "入口"
		"normal": return "战斗"
		"elite": return "精英"
		"treasure": return "宝箱"
		"shop": return "商店"
		"rest": return "休息"
		"secret": return "密室"
		"boss": return "首领"
		"exit": return "出口"
		_: return t

## 全图叠加：33 房一张图，玩家能看到自己在哪、哪些房没去过
func _draw_map_overlay() -> void:
	var f := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, VIEW), Color(0, 0, 0, 0.72))
	var w: float = float(level.map.w)
	var scale: float = (VIEW.x - 120.0) / w
	for r in level.rooms:
		var x: float = 60.0 + float(r.x0) * scale
		var rw: float = float(r.w) * scale
		var visited: bool = level.rooms_visited.has(r.index)
		var col := Color(0.25, 0.30, 0.35)
		if r.index == level.current_room:
			col = Color(1.0, 0.85, 0.35)
		elif visited:
			col = Color(0.45, 0.60, 0.55)
		draw_rect(Rect2(x, VIEW.y * 0.5 - 40, maxf(2.0, rw - 2.0), 80), col)
		draw_string(f, Vector2(x, VIEW.y * 0.5 + 56), _room_cn(r.rtype).substr(0, 2),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.9, 0.9, 0.9))
	var px: float = 60.0 + float(level.player.p.x / 16.0) * scale
	draw_line(Vector2(px, VIEW.y * 0.5 - 50), Vector2(px, VIEW.y * 0.5 + 50), Color(1, 0.3, 0.3), 2.0)
	draw_string(f, Vector2(60, 80), "第 %d 层 全图（M 关闭）" % run.floor_index,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 1, 1))
