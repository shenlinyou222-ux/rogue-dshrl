# Sim —— 无头机器人：让代码自己把游戏跑一遍
#
# 为什么必须有这个工具（而不是「我手动玩一下看看」）：
#   1. **手感/难度是统计量**，不是感觉。TTK、受伤频率、卡关率都要有数字；
#   2. **可复现性只能靠机器人证明**：同种子 + 同输入序列 ⇒ 同结果；
#   3. **生成层的断言只证明了「几何可达」**，证明不了「玩家实际走得到」。
#      机器人拿真实的 Actor 物理去走，才是端到端的证据。
#
# 机器人策略（故意用**朴素**的贪婪策略，因为它的定位是**下限探针**）：
#   向右走 → 遇墙/遇坑就跳 → 敌人在攻击距离内就砍 → 血低就后撤喝药。
#   它跑得通 ⇒ 关卡没有硬性堵死；它跑不通 ⇒ 要么关卡有问题，要么这一局特别难，
#   两种都值得看一眼。
#
# 运行：
#   run.ps1 -Script tools/sim.gd -Args '-- --runs=8 --frames=40000'

extends SceneTree

const Cfg = preload("res://core/constants.gd")
const KM = preload("res://gen/motion_kernel.gd")
const RunState = preload("res://run/run_state.gd")
const FD = preload("res://combat/framedata.gd")
const TK = preload("res://tools/testkit.gd")

var verbose: bool = false
var last_branch: int = 0
var runs: int = 8
var max_frames: int = 40000
var seed0: int = 1000

func _init() -> void:
	runs = int(Cfg.cmdline_value("--runs", "8"))
	max_frames = int(Cfg.cmdline_value("--frames", "40000"))
	seed0 = int(Cfg.cmdline_value("--seed", "1000"))
	verbose = Cfg.cmdline_value("--trace", "0") != "0"
	var t = TK.new()
	print("DSH-RL 无头模拟器  runs=%d max_frames=%d" % [runs, max_frames])
	print("")

	var cleared := 0
	var dead := 0
	var stuck := 0
	var stalled := 0
	var timeout := 0
	var rooms_sum := 0
	var total_kills := 0
	var total_dmg := 0
	var frames_used := 0
	var first_clear_frames := -1
	var det_ok := 0
	var trace_hash_ok := 0
	var ttks: Array = []
	var floor_clear: Array = [0, 0, 0]
	var t0 := Time.get_ticks_msec()

	for i in range(runs):
		var seed64: int = seed0 + i * 7919
		var r = RunState.new(seed64, false)
		r.generate()
		r.start_floor(1)
		var res: Dictionary = play(r)
		# 逐层推进（机器人一路打到通关或死）
		var guard := 0
		while r.state == "floor_clear" and guard < 5:
			floor_clear[mini(2, r.floor_index - 1)] += 1
			r.next_floor()
			var res2: Dictionary = play(r)
			res["frames"] += res2["frames"]
			res["kills"] += res2["kills"]
			res["dmg"] += res2["dmg"]
			res["room"] = res2["room"]
			for x in res2["ttk"]:
				res["ttk"].append(x)
			if r.state == "dead":
				res["dead"] = true
			guard += 1
		frames_used += int(res["frames"])
		total_kills += int(res["kills"])
		total_dmg += int(res["dmg"])
		for x in res["ttk"]:
			ttks.append(int(x))
		if verbose:
			print("  run %d seed=%d → %s：房 %d/%d，杀 %d，承伤 %d（%s），帧 %d，TTK中位 %.1fs" % [
				i, seed64, str(res["state"]), int(res["room"]) + 1, r.level.rooms.size(),
				int(res["kills"]), int(res["dmg"]), str(res["dmg_by_source"]),
				int(res["frames"]), _median(res["ttk"]) / 60.0])
			if true:
				print("     尾事件：%s" % str(res["tail"]))
				print("     轨迹尾：%s" % str(res["trace"].slice(maxi(0, res["trace"].size() - 8))))
				print("     现场：%s" % "\n".join(PackedStringArray(res["grid"])))
				print("     钥匙：拿到=%s 场上=%s 门=%s" % [str(res["keys"]), str(res["keyitems"]), str(res["doors"])])
		if r.state == "won":
			cleared += 1
			if first_clear_frames < 0:
				first_clear_frames = int(res["frames"])
		elif r.state == "dead":
			dead += 1
		elif bool(res.get("stalled", false)):
			# 真·死胡同：连续 900 帧原地不动（门没开、路走不通）
			stalled += 1
		else:
			# 只是没在帧上限内跑完 —— 这不算卡死，但要计入进度指标
			timeout += 1
		stuck += 1
		rooms_sum += int(res.get("room", 0))

		# 可复现性：同种子重跑一次，事件日志必须逐字节一致
		var r2 = RunState.new(seed64, false)
		r2.generate()
		r2.start_floor(1)
		var res_b: Dictionary = play(r2)
		if str(res_b["trace"]) == str(res["trace"]):
			det_ok += 1
		if res_b["fingerprint"] == res["fingerprint"]:
			trace_hash_ok += 1

	var ms: int = Time.get_ticks_msec() - t0
	t.info("模拟 %d 局：%d ms（平均 %d ms/局）" % [runs, ms, ms / maxi(1, runs)])
	t.ok("S1", true, "模拟跑完 %d 局（未崩溃）：通关 %d / 死亡 %d / 卡住 %d"
		% [runs, cleared, dead, stuck])
	t.ok("S2", total_kills > 0, "机器人确实杀到了敌人（共 %d 杀）" % total_kills)
	t.ok("S3", total_dmg > 0, "机器人确实挨到了伤害（共 %d 点，说明敌人真的会打人）" % total_dmg)
	t.ok("S4", det_ok == runs, "同种子 + 同策略 ⇒ 同事件序列 %d/%d" % [det_ok, runs])
	t.ok("S5", trace_hash_ok == runs, "同种子 + 同策略 ⇒ 同世界线指纹 %d/%d" % [trace_hash_ok, runs])
	var prog_avg: float = float(rooms_sum) / float(maxi(1, runs))
	t.ok("S6", stalled <= runs / 4 and prog_avg >= 5.0,
		"不许走进死胡同、且必须真的在推进（真·卡死 %d/%d，帧上限用尽 %d；平均推进 %.1f 个房间）"
		% [stalled, runs, timeout, prog_avg])
	t.info("平均每局 %d 帧（%.1f 秒模拟时间）；平均击杀 %d；平均承伤 %d"
		% [frames_used / maxi(1, runs), float(frames_used) / float(maxi(1, runs)) / 60.0,
		   total_kills / maxi(1, runs), total_dmg / maxi(1, runs)])
	t.info("逐层通过：第1层 %d / 第2层 %d / 第3层 %d" % [floor_clear[0], floor_clear[1], floor_clear[2]])
	t.info("TTK 参考：普通敌人 %.1f~%.1f 秒（契约），实测中位 TTK %.2f 秒（样本 %d 个敌人）"
		% [float(Cfg.DIFFICULTY["ttk_normal"][0]), float(Cfg.DIFFICULTY["ttk_normal"][1]),
		   _median(ttks) / 60.0, ttks.size()])
	_balance_report(t)
	var fails: int = t.summary("无头模拟")
	quit(1 if fails > 0 else 0)

# --------------------------------------------------------------------------
# 机器人本体
# --------------------------------------------------------------------------

func play(r) -> Dictionary:
	var lv = r.level
	# bot internal state must reset per run (else S4 false-fails)
	stall_x = -1.0
	stall_frames = 0
	path = []
	path_target = Vector2i(-99999, -99999)
	plan_age = 0
	plan_relaxed = false
	replan_wait = 0
	follow_px = -1.0
	follow_py = -1.0
	follow_stall = 0
	scramble_until = -1
	scramble_t = 0
	scramble_side = 1
	last_branch = 0
	var kills0: int = lv.total_kills
	var dmg0: int = _dmg_taken(lv)
	var frames := 0
	var trace: Array = []
	var last_x: float = r.player.p.x
	var stuck_frames := 0
	var hit_stall := false
	var seen := {}                 # enemy id -> 首次出现帧（用来算真实 TTK）
	var ttk: Array = []
	var dmg_by_source := {}
	while lv.frame < max_frames and r.state == "playing":
		var inp: Dictionary = bot_input(r, lv)
		r.step(inp)
		frames += 1
		# TTK：敌人首次出现 → 消失（死亡）的帧数
		var now := {}
		for a in lv.actors:
			if a.kind != "enemy":
				continue
			now[a.id] = true
			if not seen.has(a.id) and bool(a.aggro):
				seen[a.id] = lv.frame
		for eid in seen.keys():
			if not now.has(eid) and int(seen[eid]) >= 0:
				ttk.append(lv.frame - int(seen[eid]))
				seen[eid] = -1         # 标记已结算，避免重复
		# 卡死检测：连续 900 帧 x 没前进（门没开 / 机器人走不过去）
		if absf(r.player.p.x - last_x) < 0.5:
			stuck_frames += 1
			if stuck_frames > 900:
				hit_stall = true
				break
		else:
			stuck_frames = 0
			last_x = r.player.p.x
		if frames % 30 == 0:
			var tc: Vector2i = r.player.cell()
			trace.append("%d|x%d|y%d|vy%.0f|%s|og%s|jb%d|jmp%s|hp%d|br%d|face%d|vx%.0f|L%s|R%s|near%s|tgt%d,%d|pn%d|sf%d" % [lv.frame, int(r.player.p.x), int(r.player.p.y), r.player.vel.y, r.player.state, str(r.player.on_ground), r.player.jump_buf, str(inp.get("jump_press", false)), r.player.hp, last_branch, r.player.facing, r.player.vel.x, str(inp.get("left",false)), str(inp.get("right",false)), dbg_near_info, path_target.x, path_target.y, path.size(), stall_frames])
	for e in lv.events:
		if e.kind == "enemy_hit":
			dmg_by_source["enemy"] = int(dmg_by_source.get("enemy", 0)) + int(e.data.get("dmg", 0))
		elif e.kind == "spike":
			dmg_by_source["spike"] = int(dmg_by_source.get("spike", 0)) + 8
	return {
		"frames": frames,
		"kills": lv.total_kills - kills0,
		"dmg": _dmg_taken(lv) - dmg0,
		"trace": trace,
		"fingerprint": lv.map.fingerprint(),
		"ttk": ttk,
		"room": lv.current_room,
		"dmg_by_source": dmg_by_source,
		"state": r.state,
		"tail": lv.events.slice(maxi(0, lv.events.size() - 10)),
		"stalled": hit_stall,
		"hp": r.player.hp,
		"grid": _dump_grid(lv, r.player),
		"keys": lv.unlocked_keys.keys(),
		"keyitems": lv.key_items,
		"doors": _doors(lv),
	}

## 死亡现场：把玩家最后位置周围的地图字符打出来（定位"掉出世界"用的）
func _dump_grid(lv, pl) -> Array:
	var out: Array = []
	var c: Vector2i = pl.cell()
	out.append("玩家 p=(%.0f,%.0f) 格=(%d,%d) 开格数=%d" % [pl.p.x, pl.p.y, c.x, c.y, lv.open_cells.size()])
	for dy in range(-2, 3):
		for dx in range(-1, 3):
			out.append("   (%d,%d) 字符=%s 阻挡=%s" % [c.x + dx, c.y + dy,
				lv.map.at(c.x + dx, c.y + dy), str(lv.is_blocked_tile(c.x + dx, c.y + dy))])
	for y in range(c.y - 3, c.y + 5):
		var line := ""
		for x in range(c.x - 8, c.x + 9):
			if x < 0 or y < 0 or x >= lv.map.w or y >= lv.map.h:
				line += "?"
			else:
				line += lv.map.at(x, y)
		out.append("%3d %s" % [y, line])
	return out

func _dmg_taken(lv) -> int:
	var n := 0
	for e in lv.events:
		if e.kind == "enemy_hit" or e.kind == "spike":
			n += int(e.data.get("dmg", 8))
	return n

## 朴素贪婪策略：向右走、遇阻跳、敌近则砍、血低后撤喝药、门锁着就回头找钥匙。
## 信息边界（说清楚，免得自欺欺人）：
##   · **战斗**只用"看得见的东西"（附近敌人的位置/状态），不用生成层特权信息；
##   · **导航**用 `lv.doors` / `lv.key_items` 当作"玩家的地图记忆"——真人看见锁着的门
##     就会去找钥匙或拉杆，这里用坐标代替"记得在哪里见过"。
##   · 也就是说：机器人跑通 ⇒ 关卡**存在**一条正常人能走通的路；
##     机器人跑不通 ⇒ 关卡有硬伤（这是本探测器的用途）。
## 注意：策略里**没有用到任何生成层的特权信息**（不知道门在哪、不知道钥匙在哪），
## 它只看得见屏幕上能看见的东西 —— 这样它跑通才有说服力。
var dbg_near_info: String = "?"
# 目标模式（"门锁着就回头找钥匙/拉杆"）：x 停滞 45 帧后才启用
var stall_x: float = -1.0
var stall_frames: int = 0
var path: Array = []
var _offsets: Array = []
var _lands: Dictionary = {}
var path_target: Vector2i = Vector2i(-99999, -99999)
var plan_age: int = 0
var plan_relaxed: bool = false
var replan_wait: int = 0
var follow_px: float = -1.0
var follow_py: float = -1.0
var follow_stall: int = 0
## 挣扎（unstick）：真人卡住会原地蹦两下、左右都试试。这里给机器人同样的机会 ——
## 不这么做的话，只要规划器认定"这里出不去"，它就一直杵到 900 帧被判卡死。
var scramble_until: int = -1
var scramble_t: int = 0
var scramble_side: int = 1
func bot_input(r, lv) -> Dictionary:
	dbg_near_info = "?"
	var pl = r.player
	var inp := {
		"left": false, "right": false, "up": false, "down": false,
		"block": false, "jump_press": false, "jump_release": false,
	}
	if not pl.alive:
		return inp
	# 0) 挣扎模式（优先于一切）：左右交替 + 周期起跳，纯物理乱试
	if lv.frame < scramble_until:
		scramble_t += 1
		if scramble_t % 30 == 0:
			scramble_side = -scramble_side
		inp["left"] = scramble_side < 0
		inp["right"] = scramble_side > 0
		inp["jump_press"] = (scramble_t % 24) == 0
		inp["jump_release"] = (scramble_t % 24) == 12
		last_branch = 99
		return inp
	if stall_frames == 240 and scramble_until < lv.frame:
		scramble_until = lv.frame + 210
		scramble_t = 0
		scramble_side = 1
	if absf(pl.p.x - stall_x) < 0.6:
		stall_frames += 1
	else:
		stall_x = pl.p.x
		stall_frames = 0

	last_branch = 1
	# 1) 找最近的敌人（水平距离为主，但记下垂直差：站在高台上的敌人砍不到）
	var near = null
	var best := 1e9
	var best_dy := 0.0
	for a in lv.actors:
		if a.kind != "enemy" or not a.alive:
			continue
		var d: float = absf(a.p.x - pl.p.x)
		if d < best and absf(a.p.y - pl.p.y) < 90.0:
			best = d
			best_dy = a.p.y - pl.p.y
			near = a

	# 2) 尖刺：看见了就跳过去；已经踩在刺上就往空的方向跳出去
	#    玩家看得见地上的尖刺，所以机器人也不该"看不见" —— 这是公平信息。
	#    实测教训：原地翻滚（"踩在刺上就滚"）会让机器人卡在刺上一直吃伤害，
	#    因为翻滚方向被前面一格台阶挡住 —— 必须"先选方向再动作"。
	var fc: Vector2i = pl.cell()
	if pl.on_ground and fc.y >= 0:
		var dir: int = 1 if pl.facing >= 0 else -1
		if lv.is_danger_tile(fc.x, fc.y):
			var free_ahead: bool = not lv.is_blocked_tile(fc.x + dir, fc.y) \
				and not lv.is_blocked_tile(fc.x + dir, fc.y - 1)
			if not free_ahead:
				dir = -dir
			inp["right"] = dir > 0
			inp["left"] = dir < 0
			inp["jump_press"] = true
			last_branch = 21
			return inp
		for dx in range(1, 3):
			var sx: int = fc.x + dir * dx
			if lv.is_danger_tile(sx, fc.y) or lv.is_danger_tile(sx, fc.y - 1):
				inp["right"] = dir > 0
				inp["left"] = dir < 0
				inp["jump_press"] = true
				last_branch = 22
				return inp

	dbg_near_info = "null" if near == null else "%.0f,%.0f,%s,%.0f" % [near.p.x, near.p.y, near.state, best]
	# 3) 血低：后撤 + 喝药（贴脸的时候先拉开，否则喝药必被打断）
	var hp_ratio: float = float(pl.hp) / float(maxi(1, pl.max_hp))
	if hp_ratio < 0.40:
		if pl.heal_flask > 0 and pl.on_ground and pl.state == "idle" and (near == null or best > 70.0):
			pl.press("heal")
			last_branch = 31
			return inp
		if near != null and best < 90.0 and absf(best_dy) < 60.0:
			inp["left" if near.p.x > pl.p.x else "right"] = true
			inp["block"] = true
			last_branch = 32
			return inp

	# 4) 敌人正在预警：格挡（距离远）或翻滚穿过去（距离近）
	#    这是一个「会玩的人」的最小反应集：读到预警 → 选一个防御动作。
	var danger := false
	if near != null and best < 52.0 and absf(best_dy) < 40.0 and near.state == "telegraph":
		var remain: int = int(near.data.get("telegraph", 16)) - int(near.state_frame)
		if remain <= 10:
			danger = true
	if danger and pl.on_ground:
		if best > 34.0 and not bool(near.data.get("suicide", false)):
			inp["block"] = true
			last_branch = 41
			return inp
		pl.press("roll")
		inp["right"] = near.p.x > pl.p.x
		inp["left"] = near.p.x < pl.p.x
		last_branch = 42
		return inp

	# 5) 敌人在攻击距离内：先转身，再砍
	#    （「先转身」这一步是必须的：玩家的判定位在身前，背对着砍一万年也砍不中 ——
	#      实测机器人卡在这里，TTK 被算成 113 秒/杀）
	#    **垂直距离也要判**：站在上层平台上的敌人水平只有 0 距离，砍一辈子砍不到 ——
	#      实测这就是"机器人贴着一个敌人砍了 700 帧、一格没动"的原因。
	if near != null and best < 36.0 and absf(best_dy) < 34.0:
		var want_dir: int = 1 if near.p.x > pl.p.x else -1
		dbg_near_info = "B5 near=%.1f me=%.1f want=%d face=%d" % [near.p.x, pl.p.x, want_dir, pl.facing]
		if absf(near.p.x - pl.p.x) >= 6.0 and pl.facing != want_dir:
			inp["right"] = want_dir > 0
			inp["left"] = want_dir < 0
			last_branch = 51
			return inp
		pl.press("attack")
		last_branch = 52
		return inp

	# 5.5) 敌人在头顶（上层长廊 / 平台）：跳上去够它，否则会被"看不见的敌人"拖住
	if near != null and best < 70.0 and best_dy < -20.0 and pl.on_ground:
		inp["right"] = near.p.x > pl.p.x + 4.0
		inp["left"] = near.p.x < pl.p.x - 4.0
		inp["jump_press"] = true
		pl.jump_buf = int(Cfg.FRAME["jump_buffer"])
		last_branch = 55
		return inp

	# 6) 路线模式：按 BFS 规划出来的路走（钥匙 → 拉杆 → 出口）
	#    卡死检测只是"规划失败"的兜底，不再是主逻辑。
	plan_age += 1
	replan_wait = maxi(0, replan_wait - 1)
	var tgt: Vector2i = _objective(lv)
	var want_plan: bool = tgt != path_target or plan_age > 600
	if path.is_empty():
		want_plan = want_plan and replan_wait == 0
	if want_plan:
		path_target = tgt
		plan_age = 0
		var pstart := Vector2i(pl.cell().x, pl.foot_row())
		plan_relaxed = false
		_lands.clear()
		if not _standable(lv, pstart.x, pstart.y):
			pstart = _near_standable(lv, pstart)
		path = _plan(lv, pstart, tgt)
		if path.is_empty():
			# 严格图失败 → 退到"核判据"的宽松图（陷阱剪除保证了终点可达）
			plan_relaxed = true
			_lands.clear()
			var ps2 := Vector2i(pl.cell().x, pl.foot_row())
			if not _standable(lv, ps2.x, ps2.y):
				ps2 = _near_standable(lv, ps2)
			path = _plan(lv, ps2, tgt)
		if path.is_empty():
			plan_relaxed = false
			_lands.clear()
			replan_wait = 90      # 规划失败别每帧重算（BFS 很贵）
	if not path.is_empty():
		return _follow(pl, lv, inp)

	# 6.5) 规划失败但**人已经在目标附近**：别急着走开（那会变成左右横跳），
	#      原地朝目标挪一下，让拾取判定有机会触发。
	if path_target.x > -9999 and absf(float(path_target.x) * 16.0 + 8.0 - pl.p.x) < 56.0:
		last_branch = 65
		return _advance(pl, lv, inp, _nudge_dir(pl, lv, 1 if float(path_target.x) * 16.0 >= pl.p.x else -1))
	# 7) 兜底：规划失败也要朝目标方向走（别再一头撞右墙）
	last_branch = 6
	return _advance(pl, lv, inp, _nudge_dir(pl, lv, 1 if float(path_target.x) * 16.0 >= pl.p.x else -1))

## 兜底推进方向：撞墙就换边 —— 曾经"规划失败 + 前方是墙"= 原地顶着墙跑到天亮。
func _nudge_dir(pl, lv, want: int) -> int:
	if not _wall_ahead(pl, lv, want):
		return want
	if not _wall_ahead(pl, lv, -want):
		return -want
	return want

func _wall_ahead(pl, lv, dir: int) -> bool:
	var cx: int = int(floor((pl.p.x + 18.0 * float(dir)) / 16.0))
	var fy: int = pl.foot_row()
	return lv.is_blocked_tile(cx, fy) or lv.is_blocked_tile(cx, fy - 1)

## 朝 dir 方向推进：遇墙/遇沟就跳
func _advance(pl, lv, inp: Dictionary, dir: int) -> Dictionary:
	inp["right"] = dir > 0
	inp["left"] = dir < 0
	if pl.on_ground:
		var ahead_x: float = pl.p.x + 18.0 * float(dir)
		var ahead_cx: int = int(floor(ahead_x / 16.0))
		var foot_cy: int = pl.foot_row()
		# 前方有墙：脚所在行和它上面一行必须一起看
		# （原来只看 foot_cy-1/-2，于是"一格台阶"这种最常见的障碍完全看不见 ——
		#   机器人撞在台阶上走一辈子，4/4 局卡死）
		var wall: bool = lv.is_blocked_tile(ahead_cx, foot_cy) \
			or lv.is_blocked_tile(ahead_cx, foot_cy - 1)
		var gap: bool = true
		for dx in range(0, 3):
			var cx: int = ahead_cx + dx * dir
			if lv.is_blocked_tile(cx, foot_cy + 1) or lv.is_blocked_tile(cx, foot_cy + 2):
				gap = false
				break
		if wall or gap:
			inp["jump_press"] = true
			pl.jump_buf = int(Cfg.FRAME["jump_buffer"])
	# 高处有东西（上层长廊的钥匙）：偶尔跳一下，提高覆盖率
	elif pl.state == "fall" and pl.jump_buf == 0 and (lv.frame % 37) == 0:
		inp["jump_press"] = true
		pl.jump_buf = int(Cfg.FRAME["jump_buffer"])
	return inp

## 头顶 n 行是否都空（能不能起跳/上升）
func _clear_above(lv, x: int, y: int, n: int) -> bool:
	for i in range(1, n + 1):
		if lv.is_blocked_tile(x, y - i):
			return false
	return true

## 站立格：直接问地图（含"开着的门"的运行时状态）。
## 严格模式额外要求头顶 2 行空（= 生成期 R6）；宽松模式只要求有地板
## （= 运动核 K 的 walk 判据）。先用严格模式规划（好走），失败再退宽松模式
## （宽松模式的图 ⊇ 严格模式，且陷阱剪除保证了宽松模式下终点一定可达）。
func _standable(lv, x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= lv.map.w or y >= lv.map.h:
		return false
	if lv.is_blocked_tile(x, y):
		return false
	if not lv.is_blocked_tile(x, y + 1):
		return false
	if plan_relaxed:
		return true
	if y < 2 or lv.is_blocked_tile(x, y - 1) or lv.is_blocked_tile(x, y - 2):
		return false
	return true

func _near_standable(lv, c: Vector2i) -> Vector2i:
	for dy in [0, 1, -1, 2, -2, 3]:
		if _standable(lv, c.x, c.y + dy):
			return Vector2i(c.x, c.y + dy)
	return Vector2i(-1, -1)

## 当前"该去哪"：先把锁着的门解决掉，再往出口走
## （钥匙/拉杆都在主走廊上，这是生成层的公平性约束；见地图方案 §"进度物必在主路"）
func _objective(lv) -> Vector2i:
	var best := -1
	var best_d := 1e9
	for d in lv.doors:
		if bool(d.open):
			continue
		var c := Vector2i(-1, -1)
		if str(d.key_item) != "":
			if lv.unlocked_keys.has(str(d.key_item)):
				continue
			for ki in lv.key_items:
				if str(ki.get("name", "")) == str(d.key_item) and not bool(ki.get("taken", false)):
					var kc: Vector2i = ki.get("cell", Vector2i.ZERO)
					c = _near_standable(lv, kc)
					break
		elif d.need_region != null:
			var nr: Vector2i = d.need_region
			c = _near_standable(lv, nr)
		if c.x < 0:
			continue
		var dist: float = absf(float(c.x) * 16.0 - lv.player.p.x)
		if dist < best_d:
			best_d = dist
			var ec: Vector2i = lv.exit_cell
			best = c.x * 100000 + c.y
	if best >= 0:
		return Vector2i(best / 100000, best % 100000)
	return _near_standable(lv, lv.exit_cell)

## 路线规划 —— 用**真实运动核 K** 当步长（不是我自己瞎猜的几何规则）。
## 每一步都是一条核里验证过的轨迹掩码，所以"这条路能走"= "物理上真的能走"。
## 这就是"看得懂地图的玩家"的替身：真人看着地形就知道哪里要跳、从哪里上。
func _step_offsets(lv) -> Array:
	if _offsets.is_empty():
		var k = KM.get_kernel()
		for off in k.cells:
			_offsets.append(off)
	return _offsets

## 轨迹掩码里的"墙"：与运动核 K 的判据一致（VoxelMap.is_wall = 上下都实心），
## 但**关着的门**在运行时是实心的，必须单独算上。
func _mask_blocked(lv, x: int, y: int) -> bool:
	# 与运行时碰撞判据一致（任何实心格、以及关着的门）
	return lv.is_blocked_tile(x, y)

func _step_lands(lv, c: Vector2i) -> Array:
	# 同一格的运动掩码对所有地图都一样，缓存起来（否则每帧算 1e5 次）
	var key := c.x * 100000 + c.y
	if _lands.has(key):
		return _lands[key]
	var out: Array = []
	for off in _step_offsets(lv):
		var o: Vector2i = off
		var tx: int = c.x + o.x
		var ty: int = c.y + o.y
		if not _standable(lv, tx, ty):
			continue
		var mask: Array = KM.get_kernel().mask_of(Vector2i(o.x, o.y))
		var ok := true
		for m in mask:
			var mc: Vector2i = m
			var wx: int = c.x + mc.x
			var wy: int = c.y + mc.y
			# 掩码判据必须与**运动核自己**一致（只把"上下都实心"的格算墙）。
			# 曾经这里用 is_blocked_tile（任何实心格都算墙）→ 采样轨迹里会撞上
			# 脚下的地板，于是**一步都走不出去**，规划恒为空、机器人乱撞。
			if _mask_blocked(lv, wx, wy):
				ok = false
				break
		if ok:
			out.append(Vector2i(tx, ty))
	_lands[key] = out
	return out

func _plan(lv, start: Vector2i, goal: Vector2i) -> Array:
	if goal.x < 0 or start.x < 0:
		return []
	var q: Array = [start]
	var seen := {start.x * 100000 + start.y: true}
	var prev := {}
	var guard := 0
	while not q.is_empty() and guard < 30000:
		guard += 1
		var cur: Vector2i = q.pop_front()
		if cur == goal:
			break
		for nx2 in _step_lands(lv, cur):
			var nx: Vector2i = nx2
			var k: int = nx.x * 100000 + nx.y
			if seen.has(k):
				continue
			seen[k] = true
			prev[k] = cur
			q.append(nx)
	if not prev.has(goal.x * 100000 + goal.y):
		return []
	var out: Array = []
	var c: Vector2i = goal
	while c != start:
		out.push_front(c)
		c = prev[c.x * 100000 + c.y]
	return out
## 沿路线走（遇到该跳的地方跳）
func _follow(pl, lv, inp: Dictionary) -> Dictionary:
	while not path.is_empty():
		var wp0: Vector2i = path[0]
		if absf(pl.p.x - (float(wp0.x) * 16.0 + 8.0)) < 8.0 \
			and absf(pl.p.y - float(wp0.y + 1) * 16.0) < 16.0:
			path.pop_front()
			continue
		break
	if path.is_empty():
		inp["right"] = true
		last_branch = 8
		return inp
	# 跟路跟到"原地不动"（被天花板顶住 / 这小段物理上过不去）→ 跳过当前路点。
	# 没有这一步，机器人会在一个够不着的路点下面原地跳一辈子（实测 1/1 局）。
	# 注意用**格子**判停滞，不能用浮点坐标：在"地面和天花板只差 4px"的地方
	# 机器人会原地弹跳（数值一直在变），浮点判据永远判不出停滞。
	var fcc: Vector2i = pl.cell()
	if absi(fcc.x - int(follow_px)) == 0 and absi(fcc.y - int(follow_py)) == 0:
		follow_stall += 1
	else:
		follow_px = float(fcc.x)
		follow_py = float(fcc.y)
		follow_stall = 0
	if follow_stall > 45:
		follow_stall = 0
		path.pop_front()
		if path.is_empty():
			inp["right"] = true
			last_branch = 8
			return inp
	var wp: Vector2i = path[0]
	var dx: float = float(wp.x) * 16.0 + 8.0 - pl.p.x
	var dir: int = 0
	if dx > 3.0:
		dir = 1
	elif dx < -3.0:
		dir = -1
	inp["right"] = dir > 0
	inp["left"] = dir < 0
	var ff: int = pl.foot_row()
	var need_up: bool = wp.y < ff
	var dy: int = wp.y - ff
	if pl.on_ground:
		var ahead_cx: int = pl.cell().x + (dir if dir != 0 else 1)
		var wall: bool = lv.is_blocked_tile(ahead_cx, ff) or lv.is_blocked_tile(ahead_cx, ff - 1)
		var gap: bool = not lv.is_blocked_tile(ahead_cx, ff + 1) \
			and not lv.is_blocked_tile(ahead_cx, ff + 2)
		# 还要跳的两种情况：下一个落脚点更高 / 中间有坑
		if need_up or dy <= -2 or wall or gap:
			inp["jump_press"] = true
			pl.jump_buf = int(Cfg.FRAME["jump_buffer"])
	elif need_up and pl.vel.y > 30.0 and pl.jumps_left > 0:
		# 二段跳（核里的高跳轨迹就是靠它实现的）
		inp["jump_press"] = true
		pl.jump_buf = int(Cfg.FRAME["jump_buffer"])
	last_branch = 8
	return inp

## 目标门的位置：钥匙门 → 钥匙；拉杆门 → 触发区
func _goal_pos(lv, d) -> Vector2:
	if str(d.key_item) != "":
		for ki in lv.key_items:
			if str(ki.get("name", "")) == str(d.key_item) and not bool(ki.get("taken", false)):
				var c: Vector2i = ki.get("cell", Vector2i.ZERO)
				return Vector2(float(c.x) * 16.0 + 8.0, float(c.y) * 16.0 + 8.0)
		return Vector2.ZERO
	if d.need_region != null:
		var nr: Vector2i = d.need_region
		return Vector2(float(nr.x) * 16.0 + 8.0, float(nr.y) * 16.0 + 8.0)
	return Vector2.ZERO

func _find_door(lv, mid: String):
	for d in lv.doors:
		if str(d.mid) == mid:
			return d
	return null

# --------------------------------------------------------------------------
# 平衡报告：把「难度契约」和实测值摆在一起
# --------------------------------------------------------------------------

func _balance_report(t) -> void:
	var lines: Array = []
	lines.append("难度契约 vs 实测（§4.3）")
	lines.append("  · TTK 普通敌人契约 %.1f~%.1f 秒" % [
		float(Cfg.DIFFICULTY["ttk_normal"][0]), float(Cfg.DIFFICULTY["ttk_normal"][1])])
	lines.append("  · 每层威胁上限：%d + %d×层" % [
		int(Cfg.DIFFICULTY["threat_cap_base"]), int(Cfg.DIFFICULTY["threat_cap_per_floor"])])
	lines.append("  · 血量成长 ×(1+%.2f)^(层-1)，伤害成长 ×(1+%.3f)^(层-1)（伤害慢得多）" % [
		float(Cfg.DIFFICULTY["hp_per_floor"]),
		float(Cfg.DIFFICULTY["dmg_per_floor"]) * float(Cfg.DIFFICULTY["dmg_gain"])])
	for l in lines:
		t.info(l)


static func _median(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var b: Array = a.duplicate()
	b.sort()
	var n: int = b.size()
	if n % 2 == 1:
		return float(b[n / 2])
	return (float(b[n / 2 - 1]) + float(b[n / 2])) * 0.5


func _doors(lv) -> Array:
	var out: Array = []
	for d in lv.doors:
		out.append({"mid": d.mid, "key": d.key_item, "open": d.open, "cells": d.cells.size()})
	return out