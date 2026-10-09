# Level —— 运行时的「一层世界」
#
# 关键设计：**没有用 Godot 的物理节点**。所有运动都由 Actor 自己按帧推进。
# 这样做的三个理由：
#   1. 可复现：物理节点会引入求解器顺序/浮点误差，无头模拟器就没法做；
#   2. 可无头：tools/sim.gd 能在没有渲染、没有场景树的情况下跑完整局；
#   3. 可控：跳跃手感完全由我们的连续方程决定，与生成层的运动核 K 同源。
#
# 门的实现是「运行时开关位」而不是「换矩阵」：
#   is_blocked_tile() = 静态矩阵阻挡 ∧ 不在已开格集合里。
#   好处：与生成层的「单调布尔加」语义**逐字对应**（开门只会让格从阻挡变通行），
#   于是生成层的可达性结论可以直接搬到运行时，不需要再证一遍。

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const VM = preload("res://gen/voxel_map.gd")
const FD = preload("res://combat/framedata.gd")
const Player = preload("res://actors/player.gd")
const Enemy = preload("res://actors/enemy.gd")
const Proj = preload("res://actors/projectile.gd")
const Items = preload("res://loot/items.gd")
const Directors = preload("res://ai/director.gd")
const Rng = preload("res://core/rng.gd")

const TILE := 16

class Pickup:
	var cell: Vector2i = Vector2i.ZERO
	var item: Dictionary = {}
	var kind: String = "pickup"
	var taken: bool = false
	var bob: int = 0

class Door:
	var mid: String = ""
	var cells: Array = []
	var key_item: String = ""
	var need_region = null
	var open: bool = false
	var kind: String = "door"

var floor = null                    # Layout.Floor
var map = null                      # VoxelMap（门关闭状态）
var floor_index: int = 1
var rooms: Array = []
var floor_enemies: Array = []       # 六头产物（enemy 头）
var floor_loot: Array = []          # loot 头
var floor_event = null              # event 头
var decor_cfg: Array = []
var event = null

var frame: int = 0
var player = null
var actors: Array = []
var projectiles: Array = []
var pickups: Array = []
var doors: Array = []
var open_cells: Dictionary = {}
var open_cells_list: Array = []
var log_lines: Array = []
var events: Array = []              # 结构化事件（AI 导演层读）
var rng = null
var unlocked_keys: Dictionary = {}
var key_items: Array = []           # [{name, cell, taken}] 场景里的钥匙
var switches_hit: Dictionary = {}
var current_room: int = 0
var rooms_cleared: Dictionary = {}
var spawn_point: Vector2i = Vector2i.ZERO
var exit_cell: Vector2i = Vector2i.ZERO
var boss_spawned: bool = false
var director = null
var enemies_alive_cache: int = 0
var ctx: Dictionary = {}
var difficulty_mult: float = 1.0
var finished: bool = false
var failed: bool = false
var total_kills: int = 0
var total_damage_taken: int = 0
var rooms_visited: Dictionary = {}
var window_dmg_dealt: Array = []
var window_dmg_taken: Array = []
# 导演层可改的运行参数（全部是**参数**，不是机制）
var pacing_frames: int = 180
var loot_rarity_delta: int = 0
var pending_affix: String = ""
## 掉落物生成的种子（= 本局种子），保证「同种子 ⇒ 同掉落序列」
var drop_seed: int = 0
var hint_text: String = ""

# --------------------------------------------------------------------------
# 构建
# --------------------------------------------------------------------------

func build(p_floor, floor_idx: int, spec, player_ref, direc,
		   enemies: Array, loot: Array, decor: Array, ev) -> void:
	floor = p_floor
	map = p_floor.base
	floor_index = floor_idx
	drop_seed = int(spec.seed64)
	rooms = p_floor.rooms
	player = player_ref
	director = direc
	floor_enemies = enemies
	floor_loot = loot
	decor_cfg = decor
	floor_event = ev
	event = ev
	rng = Rng.stream(spec.version_key, spec.seed64, floor_idx, "runtime", "v1")
	spawn_point = p_floor.spawn
	exit_cell = p_floor.goal
	frame = 0

	# 机关 → 运行时门
	for m in p_floor.mechanism_world_list:
		var d = Door.new()
		d.mid = m.mid
		d.cells = m.pass_cells
		d.key_item = str(m.key_item) if m.key_item != null else ""
		d.need_region = m.need_region
		d.kind = m.kind
		doors.append(d)

	# 玩家落到本层入口（player 跨层复用，所以每层都要重新挂 level 引用）
	player.setup(self, "player", float(spawn_point.x) * 16.0 + 8.0,
		float(spawn_point.y + 1) * 16.0)
	player.vel = Vector2.ZERO
	player.alive = true
	player.state = "idle"
	player.state_frame = 0
	player.keys_held.clear()
	actors = [player]

	# 敌人
	var idx := 0
	for e in floor_enemies:
		var arch: String = str(e.archetype)
		var is_boss: bool = rooms[e.room_index].rtype == "boss"
		if is_boss:
			arch = "boss"
		var stats: Dictionary = FD.enemy_stats(arch, floor_idx, bool(e.elite))
		var en = Enemy.new()
		en.setup_enemy(self, arch, float(e.cell.x) * 16.0 + 8.0,
			float(e.cell.y + 1) * 16.0, floor_idx, bool(e.elite), str(e.affix), stats)
		en.id = 1000 + idx
		if e.facing != 0:
			en.facing = int(e.facing)
		en.ctx = ctx.duplicate()
		# 全部敌人**初始未警觉**，玩家靠近 ~9 格才醒（行为树里的 aggro 判定）。
		# 为什么不一进房就全体扑上来：11 个房间 × 6 个敌人如果全屏仇恨，
		# 每个房间都会变成「一次性 6 打 1」，节奏没有起伏，玩家也读不过来。
		en.aggro = false
		actors.append(en)
		idx += 1

	# 掉落物
	var li := 0
	for d in floor_loot:
		var pk = Pickup.new()
		pk.cell = d.cell
		pk.kind = str(d.kind)
		var luck: float = 0.5 + float(spec.theta_f("loot"))
		var kind: String = "weapon" if (li % 3) == 0 else ("amulet" if (li % 3) == 1 else "currency")
		if pk.kind == "chest":
			kind = "weapon" if (li % 2) == 0 else "amulet"
		pk.item = Items.roll_item(spec.version_key, spec.seed64, floor_idx, li, luck, kind)
		if int(d.rarity) >= 0:
			pk.item["rarity"] = int(d.rarity)
			pk.item["rarity_name"] = str(Cfg.RARITY[int(d.rarity)])
			pk.item["base_power"] = Cfg.RARITY_POWER[str(Cfg.RARITY[int(d.rarity)])]
		pickups.append(pk)
		li += 1

	# 钥匙：不是掉落物，是「走到就拿到」的场景物件（地图上写的是 K 字符）
	for kname in p_floor.mechanism_items.keys():
		key_items.append({"name": str(kname), "cell": p_floor.mechanism_items[kname],
			"taken": false})

	# BOSS：最后一层的守关者，站在终点前若干格的地面上（BOSS 体型 40×34，要净空）
	if floor_idx >= int(Cfg.RUN["floors"]):
		_spawn_boss(p_floor)

	# 本层主题/诅咒 → 运行时效果
	if floor_event != null:
		event = floor_event
		if player != null and str(floor_event.curse).begins_with("血月"):
			for a in actors:
				if a.kind == "enemy":
					a.ctx["aggression"] = clampf(float(a.ctx.get("aggression", 0.5)) + 0.15, 0.0, 1.0)
	current_room = floor.room_at_x(int(player.p.x / 16.0))
	if current_room < 0:
		current_room = 0

func p_floor_enemies() -> Array:
	return floor_enemies
func p_floor_loot() -> Array:
	return floor_loot
func p_floor_event():
	return floor_event

# --------------------------------------------------------------------------
# 查询
# --------------------------------------------------------------------------

func is_blocked_tile(cx: int, cy: int) -> bool:
	if cx < 0 or cy < 0 or cx >= map.w or cy >= map.h:
		return true
	if not map.is_blocked(cx, cy):
		return false
	# 已开的门格：静态是阻挡，运行时放行
	return not open_cells.has(cx * 100000 + cy)

func is_danger_tile(cx: int, cy: int) -> bool:
	if cx < 0 or cy < 0 or cx >= map.w or cy >= map.h:
		return false
	return map.at(cx, cy) == VM.DANGER

func player_room() -> int:
	if player == null:
		return 0
	return floor.room_at_x(int(floor(player.p.x / 16.0)))

func log_event(kind: String, data: Dictionary) -> void:
	events.append({"frame": frame, "kind": kind, "data": data})
	if events.size() > 4000:
		events = events.slice(events.size() - 3000, events.size())

func add_projectile(pr) -> void:
	pr.id = 900000 + projectiles.size() + frame
	projectiles.append(pr)
	actors.append(pr)

func spawn_enemy_for(src, archetype: String, count: int, cap: int) -> void:
	# 铁律 E3：玩家低血时绝不追加援军
	if player != null and float(player.hp) / float(player.max_hp) < 0.30:
		log_event("summon_blocked_lowhp", {"who": src.id})
		return
	var near := 0
	for a in actors:
		if a.kind == "enemy" and a.alive and absf(a.p.x - src.p.x) < 200.0:
			near += 1
	if near >= cap:
		log_event("summon_blocked_cap", {"who": src.id, "near": near})
		return
	for i in range(count):
		var stats: Dictionary = FD.enemy_stats(archetype, floor_index, false)
		var en = Enemy.new()
		var ox: float = 24.0 * float(i + 1) * float(1 if rng.chance(50) else -1)
		# 导演层 set_affix 原语留下的 pending_affix：下一次增援就用掉它
		# （此前这个变量写进去就没人读，等于原语白做）。
		var afx: String = pending_affix
		pending_affix = ""
		en.setup_enemy(self, archetype, src.p.x + ox, src.p.y - 8.0, floor_index, false, afx, stats)
		en.id = 1000 + actors.size()
		en.ctx = ctx.duplicate()
		actors.append(en)
		log_event("summon_spawn", {"who": src.id, "arch": archetype, "x": int(en.p.x), "affix": afx})

# --------------------------------------------------------------------------
# 主循环
# --------------------------------------------------------------------------

func step(input: Dictionary) -> void:
	if finished or failed:
		return
	frame += 1
	if player.hitstop > 0:
		# hitstop 期间世界静止（只有命中停顿在跑），这是手感的来源之一
		for a in actors:
			if a.hitstop > 0:
				a.hitstop -= 1
		return

	# 玩家
	player.step(input)
	if input.get("jump_release", false):
		player.apply_variable_jump(true)

	# 敌人：分帧思考 + 每帧推进
	var alive_count := 0
	var budget: int = 0
	for a in actors:
		if a.kind == "enemy" and a.alive:
			alive_count += 1
	budget = maxi(1, int(ceil(float(alive_count) / 4.0)))
	var slot := frame % maxi(1, budget)
	var ei := 0
	for a in actors:
		if a.kind != "enemy" or not a.alive:
			continue
		# 只有落在自己槽位的敌人才重算决策（其余仍逐帧推进状态机）
		if (ei % budget) == slot:
			a.think_timer = 0
		a.step(player)
		a.post_step()
		ei += 1

	# 投射物
	var live_proj: Array = []
	for pr in projectiles:
		if pr.alive:
			pr.step()
	for pr2 in projectiles:
		if pr2.alive:
			live_proj.append(pr2)
	projectiles = live_proj

	# 清理死亡
	var live: Array = []
	for a in actors:
		if a.kind == "projectile":
			continue
		if a.alive:
			live.append(a)
		else:
			if a.kind == "enemy":
				total_kills += 1
				_on_enemy_killed(a)
	live.append_array(live_proj)
	actors = live

	_update_pickups()
	_update_mechanisms()
	_update_room_tracking()
	_update_director()
	_check_exit()

## 击杀结算：变异回血 + 掉落物。
##
## 为什么掉落要写在这里：需求是「掉落物随机生成」，但此前只有**宝箱**会掉东西，
## 打死敌人一无所获 —— 那是"随机生成了一半"。现在击杀按概率掉，且掉落**必须确定性**：
## 用本层自己的 rng 流 + 以 total_kills 当序号，同一世界线同一操作序列必然同一掉落
## （S4 逐字节复现测试盯着这条）。
func _on_enemy_killed(a) -> void:
	log_event("enemy_died", {"who": a.id, "arch": a.archetype, "x": int(a.p.x), "y": int(a.p.y)})
	# 1) 变异：击杀回血（此前 on_kill_heal 是个空设置，从没生效过）
	if player != null and int(player.on_kill_heal) > 0 and player.hp > 0:
		var before: int = player.hp
		player.hp = mini(player.max_hp, player.hp + int(player.on_kill_heal))
		if player.hp != before:
			log_event("heal", {"who": player.id, "amount": player.hp - before, "source": "on_kill"})
	# 2) 掉落：精英必掉，普通兵按概率掉；导演层的 loot 维通过 loot_rarity_delta 加运气
	var chance: int = 38 if bool(a.elite) else 10
	chance += clampi(loot_rarity_delta, -20, 40)
	if not rng.chance(chance):
		return
	var luck: float = 0.5 + float(loot_rarity_delta) * 0.02
	var idx: int = 5000 + total_kills
	var kind: String = "weapon" if (total_kills % 2) == 0 else "currency"
	var pk = Pickup.new()
	pk.cell = a.cell()
	pk.kind = "drop"
	pk.item = Items.roll_item(Cfg.VERSION_KEY, drop_seed, floor_index, idx, luck, kind)
	pickups.append(pk)
	log_event("loot_drop", {"cell": str(pk.cell), "rarity": int(pk.item.get("rarity", 0))})

## BOSS 落位：从终点往回找第一个"站得住 + 头顶净空 3 格"的格子。
## 为什么放在终点前：第 3 层的出口是本局的最后一道门，BOSS 就该堵在那儿，
## 玩家必须读招打完（它的 super_armor/弹幕/召唤都在 framedata.BOSS 里定义好了）。
func _spawn_boss(p_floor) -> void:
	var gc: Vector2i = p_floor.goal
	var cell := Vector2i(-1, -1)
	for back in range(4, 80):
		var cx: int = gc.x - back
		if cx < 3:
			break
		for dy in range(-4, 5):
			if _boss_cell_ok(p_floor.base, cx, gc.y + dy):
				cell = Vector2i(cx, gc.y + dy)
				break
		if cell.x >= 0:
			break
	if cell.x < 0:
		log_event("boss_no_room", {})
		return
	var stats: Dictionary = FD.enemy_stats("boss", floor_index, false)
	# BOSS 表是按"玩家已成型"写的（基础 420 血）；按当前 DPS 契约要打 80 秒，太磨人。
	# 压到 25~35 秒可打完 —— 压力来自三个阶段，不是来自血条长度。
	stats["hp"] = maxi(140, int(float(stats["hp"]) * 0.35))
	var en = Enemy.new()
	en.setup_enemy(self, "boss", float(cell.x) * 16.0 + 8.0, float(cell.y + 1) * 16.0 - 0.01,
		floor_index, false, "", stats)
	en.id = 9000 + actors.size()
	en.ctx = ctx.duplicate()
	en.ctx["boss"] = true
	en.ctx["phase"] = 1
	en.aggro = false
	actors.append(en)
	boss_spawned = true
	log_event("boss_spawn", {"cell": str(cell), "hp": int(stats["hp"])})

func _boss_cell_ok(m, cx: int, cy: int) -> bool:
	if not m.standable(cx, cy):
		return false
	for dy in range(1, 4):
		if m.is_blocked(cx, cy - dy) or m.is_blocked(cx + 1, cy - dy):
			return false
	return not m.is_blocked(cx + 1, cy)

func _update_pickups() -> void:
	# 钥匙：走到就拿到（这是 1 维链上唯一不会死锁的「进度闸门」形态）
	for k in key_items:
		if k["taken"]:
			continue
		var kc: Vector2i = k["cell"]
		var kp := Vector2(float(kc.x) * 16.0 + 8.0, float(kc.y) * 16.0 + 8.0)
		if absf(player.p.x - kp.x) < 22.0 and absf(player.p.y - kp.y) < 44.0:
			k["taken"] = true
			grant_key(str(k["name"]))
			if player.keys_held != null:
				player.keys_held[str(k["name"])] = true
	for pk in pickups:
		if pk.taken:
			continue
		pk.bob += 1
		var c := Vector2(float(pk.cell.x) * 16.0 + 8.0, float(pk.cell.y) * 16.0 + 8.0)
		if player.p.distance_to(Vector2(c.x, c.y + 8.0)) < player.pickup_radius or \
			absf(player.p.x - c.x) < 20.0 and absf(player.p.y - (c.y + 16.0)) < 30.0:
			pk.taken = true
			player.inventory.append(pk.item)
			if str(pk.item.get("kind", "")) == "currency":
				player.money += int(pk.item.get("amount", 5))
			else:
				# 自动装备到空槽（demo 的省事做法；正式版应给玩家选择）
				var slot: String = str(pk.item.get("slot", "weapon_a"))
				if not player.equipped.has(slot):
					player.equip(slot, pk.item)
				elif slot == "weapon_a" and not player.equipped.has("weapon_b"):
					player.equip("weapon_b", pk.item)
				else:
					player.equip(slot, pk.item)
			log_event("pickup", {"item": pk.item.get("id", "?"), "name": pk.item.get("name", "?"),
				"rarity": int(pk.item.get("rarity", 0))})

func _update_mechanisms() -> void:
	for d in doors:
		if d.open:
			continue
		var ok := false
		if d.key_item != "":
			ok = unlocked_keys.has(d.key_item)
		if not ok and d.need_region != null:
			var nr: Vector2i = d.need_region
			var px := Vector2(float(nr.x) * 16.0 + 8.0, float(nr.y) * 16.0 + 8.0)
			if absf(player.p.x - px.x) < 40.0 and absf(player.p.y - px.y) < 48.0:
				ok = true
				switches_hit["%s" % d.mid] = true
		if ok:
			d.open = true
			for c in d.cells:
				open_cells[c.x * 100000 + c.y] = true
				open_cells_list.append(c)
			log_event("door_open", {"mid": d.mid, "kind": d.kind})
			# 音效/震动钩子（渲染层读事件）

func _update_room_tracking() -> void:
	var r: int = player_room()
	if r < 0:
		return
	if r != current_room:
		current_room = r
		if not rooms_visited.has(r):
			rooms_visited[r] = true
			log_event("room_enter", {"room": r, "type": rooms[r].rtype})
			if director != null:
				director.on_room_enter(self, r)

func _update_director() -> void:
	# 每房最多 1 次查询；查询是异步的，本帧只用当前缓冲（见 ai/director.gd）
	var want_ctx: Dictionary = ctx
	if director != null:
		director.tick(self)
		want_ctx = director.active_ctx()
	if want_ctx != ctx:
		ctx = want_ctx
		for a in actors:
			if a.kind == "enemy":
				a.ctx = ctx

func _check_exit() -> void:
	if player == null or not player.alive:
		failed = true
		return
	var ec := exit_cell
	var px := Vector2(float(ec.x) * 16.0 + 8.0, float(ec.y + 1) * 16.0)
	if absf(player.p.x - px.x) < 24.0 and absf(player.p.y - px.y) < 48.0:
		finished = true
		log_event("floor_clear", {"floor": floor_index})

## 钥匙拾取：掉落物里 kind=key 的直接进 keys_held（由 RunState 在跨层时调用）
func grant_key(name: String) -> void:
	unlocked_keys[name] = true
	log_event("key_get", {"name": name})

# --------------------------------------------------------------------------
# 统计（AI 导演层的输入）
# --------------------------------------------------------------------------

func stats_window(win: int = 360) -> Dictionary:
	var dealt := 0
	var taken := 0
	for e in events:
		if e.frame < frame - win:
			continue
		if e.kind == "player_hit":
			dealt += int(e.data.get("dmg", 0))
		elif e.kind == "enemy_hit":
			taken += int(e.data.get("dmg", 0))
	var alive := 0
	var threat := 0
	for a in actors:
		if a.kind == "enemy" and a.alive:
			alive += 1
			threat += int(FD.ENEMIES.get(a.archetype, {}).get("threat", 2))
	return {
		"hp_ratio": float(player.hp) / float(maxi(1, player.max_hp)),
		"alive": alive, "threat": threat,
		"dealt": dealt, "taken": taken,
		"room": current_room,
		"room_type": rooms[current_room].rtype if current_room >= 0 and current_room < rooms.size() else "?",
		"clean_rooms": player.clean_rooms,
		"invuln": player.invuln,
		"frame": frame,
	}
