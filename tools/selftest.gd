# DSH-RL 自检 —— 生成层（M1）
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <proj> --script tools/selftest.gd
#   （加 --quick 只跑短扫描）
#
# 断言 ID 与机制拆解 §13 的 V1 系列对齐。

extends SceneTree

const Cfg = preload("res://core/constants.gd")
const JP = preload("res://core/jump_phys.gd")
const Dig = preload("res://core/digest.gd")
const Rng = preload("res://core/rng.gd")
const MK = preload("res://gen/motion_kernel.gd")
const GM = preload("res://gen/gridmap.gd")
const VM = preload("res://gen/voxel_map.gd")
const Room = preload("res://gen/room.gd")
const Layout = preload("res://gen/layout.gd")
const RunGen = preload("res://gen/run_gen.gd")
const Heads = preload("res://gen/heads.gd")
const TK = preload("res://tools/testkit.gd")

var quick := false

func _init() -> void:
	quick = Cfg.has_quick_flag()
	var t = TK.new()
	print("DSH-RL 生成层自检  (quick=%s)" % str(quick))
	print(JP.summary())

	check_physics(t)
	var kernel = MK.get_kernel()
	check_kernel(t, kernel)
	check_corridor_sweep(t, kernel)
	check_determinism(t)
	check_mechanisms(t, kernel)
	check_rooms(t, kernel)
	check_floors(t, kernel)
	check_run(t)
	var failures: int = t.summary("生成层自检")
	quit(1 if failures > 0 else 0)

# --------------------------------------------------------------------------
# A. 物理派生常量
# --------------------------------------------------------------------------

func check_physics(t) -> void:
	t.begin("A. 跳跃物理派生常量（机制拆解 §4.1 / 地图方案 §6.3）")
	t.near("A1", JP.h_single(), 122.5, 0.05, "h_single = v0^2/(2g)")
	t.near("A2", JP.h_max(), 200.9, 0.05, "h_max = h_single*(1+k^2)")
	t.near("A3", JP.t_air(0.0), 0.35, 0.001, "t_air(同高) = v0/g")
	t.near("A4", JP.reach_x_to(0.0), 147.0, 0.5, "射程（单段跳档）")
	t.near("A5", JP.reach_x_to(JP.h_single() * 0.5), 147.0, 0.5,
		"档内滞空是常量 -> 上跳档射程与平地同值")
	t.near("A6", JP.reach_x_to(JP.h_single() * 0.999), 147.0, 0.5, "单段跳档上界")
	t.near("A7", JP.reach_x_to(JP.h_single() * 1.01), 264.6, 1.0, "二段跳档射程")
	t.near("A8", JP.t_air(JP.h_max() * 0.999), 0.63, 0.01, "二段跳档滞空")
	# 文档 §6.3 表把「下落档射程」写成 230 px（= vx*t_down(fall_max)），
	# 那是**修正前**的公式（把「起跳后再下落」当成了「静止自由落体」）。
	# 实现走的是 jumpcore.t_air(dh<0) = t_rise(0) + t_fall_from(dh, h_single)，
	# 其中 t_rise(0) 被 `dh <= 0 -> 0` 的守卫吃掉，于是 t = 0.65 s、射程 273 px。
	# （文档 §4.2 的即时代码注释写的是 0.70 s —— 那是「0.35 + 0.35」；
	#   实现少了起跳上升那 0.05 s，偏差方向是**更保守**，不是「看着能跳其实过不去」。）
	# 本作保留实现行为，并把它锁进断言，避免以后有人"顺手改对"而让 160/160 的
	# 原型结论失效。
	t.near("A9", JP.t_air(-300.0), 0.65, 0.001, "下落档滞空（实现口径）")
	t.near("A9b", JP.reach_x_to(-300.0), 273.0, 1.0, "下落档射程（实现口径）")
	t.near("A10", JP.t_down(300.0), 0.5477, 0.001, "纯自由落体时间")
	t.ok("A11", JP.reach_x_to(JP.h_max() * 1.2) < 0.0, "超出 h_max 应判不可达")
	t.near("A12", JP.safe_gap(0.0), 125.0, 0.5, "安全间距（同高）")
	t.near("A13", JP.safe_gap(JP.h_single() * 1.01), 225.0, 1.0, "安全间距（二段跳档）")

# --------------------------------------------------------------------------
# B. 运动核
# --------------------------------------------------------------------------

func check_kernel(t, kernel) -> void:
	t.begin("B. 运动核 K（地图方案 §4.5 / §6.3）")
	t.info(kernel.stats())
	t.info(kernel.gap_capacity_text())
	t.ok("B1", kernel.size() > 150 and kernel.size() < 480,
		"核规模应在 150~480，实测 %d" % kernel.size())
	t.ok("B2", not kernel.has_offset(Vector2i.ZERO), "核不能含 (0,0)")
	var d0: PackedInt32Array = kernel.allowed_dcx(0)
	t.info("dcy=0  允许 dcx = %s" % str(Array(d0)))
	t.info("dcy=-1 允许 dcx = %s" % str(Array(kernel.allowed_dcx(-1))))
	t.info("dcy=+1 允许 dcx = %s" % str(Array(kernel.allowed_dcx(1))))

	# 文档记录的实测形状：dcy=0 时 dcx ∈ (-2,-1,1,2,3,4,5)
	var d0set := {}
	for x in d0:
		d0set[x] = true
	var shape_ok := d0set.has(-2) and d0set.has(-1) and d0set.has(1) \
		and d0set.has(2) and d0set.has(3) and d0set.has(4) and d0set.has(5) \
		and not d0set.has(0)
	t.ok("B3", shape_ok, "dcy=0 的形状应与文档一致（左右不对称是物理，不是 bug）")

	# 左右不对称必须真实存在（唯一能自然造出「单向陷阱」的机制）
	t.ok("B4", d0set.has(4) and not d0set.has(-4),
		"dcy=0 必须左右不对称：向右可达 4 格、向左不可达 4 格")

	# 双向性：不变量 B 依赖 dcy=±1 都含 dcx=1
	var up := {}
	for x in kernel.allowed_dcx(-1):
		up[x] = true
	var dn := {}
	for x in kernel.allowed_dcx(1):
		dn[x] = true
	t.ok("B5", up.has(1) and up.has(-1) and dn.has(1) and dn.has(-1),
		"dcy=±1 都必须含 dcx=±1（不变量 B 的全部依据）")

	var cap: Dictionary = kernel.gap_capacity()
	t.info("缺口容量：%s" % str(cap))
	t.ok("B6", int(cap[0]) >= 1 and int(cap[-1]) >= 1 and int(cap[1]) >= 1,
		"三个相邻高差档的缺口容量都必须 >= 1 格")
	t.ok("B7", kernel.max_crossable_barrier() >= 1, "实体障碍连排上限 >= 1")

	# 核 vs 物理的双向核对（这是最关键的一条）
	var bad: Array = kernel.verify_against_physics()
	t.ok("B8", bad.is_empty(), "核 vs 物理双向核对：%d 处不一致 %s"
		% [bad.size(), str(bad.slice(0, 3))])
	t.ok("B9", kernel.compiled_at_ms < 20000,
		"核编译耗时应 < 20 s，实测 %d ms" % kernel.compiled_at_ms)

# --------------------------------------------------------------------------
# C. 走廊生成扫描（V1-02 连通性 + 构造式约束）
# --------------------------------------------------------------------------

func check_corridor_sweep(t, kernel) -> void:
	t.begin("C. 走廊生成扫描（构造性连通 + 不变量 B + 无底部后门）")
	var sizes := [[48, 26], [64, 28], [96, 34], [128, 40]]
	var seeds_per: int = 8 if quick else 40
	var total := 0
	var err_count := 0
	var first_err := ""
	var min_nodes := 1 << 30
	var max_repairs := 0
	var t0 := Time.get_ticks_msec()
	var bottom_violations := 0
	var spawn_goal_bad := 0
	for sz in sizes:
		for si in range(seeds_per):
			var spec = GM.GenSpec.new()
			spec.w = sz[0]
			spec.h = sz[1]
			spec.seed64 = 900000 + si * 7919 + sz[0] * 131
			var res: Dictionary = GM.generate(spec)
			var m = res["map"]
			var rep = res["report"]
			total += 1
			if not rep.errors.is_empty():
				err_count += 1
				if first_err == "":
					first_err = "size=%s seed=%d: %s" % [str(sz), spec.seed64, str(rep.errors[0])]
			min_nodes = mini(min_nodes, m.nodes().size())
			max_repairs = maxi(max_repairs, rep.repairs.size())
			# 坑 1：地图最后一行不能是可站立格（否则出现平行底部通道）
			for x in range(m.w):
				if m.standable(x, m.h - 1):
					bottom_violations += 1
					break
			if not m.standable(m.spawn.x, m.spawn.y) or not m.standable(m.goal.x, m.goal.y):
				spawn_goal_bad += 1
	var dt := Time.get_ticks_msec() - t0
	t.ok("C1", err_count == 0, "全部 %d 张图必须无构造性错误（失败 %d）%s"
		% [total, err_count, first_err])
	t.ok("C2", spawn_goal_bad == 0, "出生点/出口必须落在可站立格上（失败 %d）" % spawn_goal_bad)
	t.ok("C3", bottom_violations == 0,
		"地图最后一行不得出现可站立格（失败 %d）—— 这是「底部平行通道」后门" % bottom_violations)
	t.ok("C4", min_nodes > 40, "每张图的可站立格点至少 40（实测最小 %d）" % min_nodes)
	t.info("生成 %d 张图：%.0f ms（平均 %.2f ms/张），不变量 B 修复最多 %d 列"
		% [total, float(dt), float(dt) / float(maxi(1, total)), max_repairs])

	# 真实矩阵上的双向可达（不是走廊抽象图）：从出生点到出口、再回来
	var fwd_ok := 0
	var back_ok := 0
	var trial := 5 if quick else 20
	for si in range(trial):
		var spec2 = GM.GenSpec.new()
		spec2.w = 96
		spec2.h = 34
		spec2.seed64 = 4242 + si * 104729
		var res2: Dictionary = GM.generate(spec2)
		var m2 = res2["map"]
		var f: Dictionary = m2.reach_from(kernel, m2.spawn, true)
		if f.has(m2.goal):
			fwd_ok += 1
		var b: Dictionary = m2.reach_from(kernel, m2.goal, false)
		if b.has(m2.spawn):
			back_ok += 1
	t.ok("C5", fwd_ok == trial, "真实矩阵 FWD：出生点→出口 %d/%d" % [fwd_ok, trial])
	t.ok("C6", back_ok == trial, "真实矩阵 BACK：出口→出生点 %d/%d（单向陷阱检测）"
		% [back_ok, trial])

# --------------------------------------------------------------------------
# D. 确定性（V1-01 / V1-02b）
# --------------------------------------------------------------------------

func check_determinism(t) -> void:
	t.begin("D. 世界线确定性（V1-01 / V1-02b）")
	var fp := []
	var keys := []
	for si in range(6):
		var spec = GM.GenSpec.new()
		spec.w = 96
		spec.h = 34
		spec.seed64 = 777000 + si
		var r1: Dictionary = GM.generate(spec)
		var r2: Dictionary = GM.generate(spec)
		fp.append(r1["map"].fingerprint())
		keys.append(r1["report"].height.duplicate())
		t.ok("D1.%d" % si, r1["map"].fingerprint() == r2["map"].fingerprint(),
			"同 seed 两次生成指纹必须一致")
	# 不同种子必须给出不同指纹
	var uniq := {}
	for f in fp:
		uniq[f] = true
	t.ok("D2", uniq.size() == fp.size(), "不同种子必须给出不同指纹（%d 个种子 -> %d 个指纹）"
		% [fp.size(), uniq.size()])
	# 高度场也必须一致
	var spec_a = GM.GenSpec.new()
	spec_a.seed64 = 12345
	var ra: Dictionary = GM.generate(spec_a)
	var spec_b = GM.GenSpec.new()
	spec_b.seed64 = 12345
	var rb: Dictionary = GM.generate(spec_b)
	t.ok("D3", str(ra["report"].height) == str(rb["report"].height), "高度场必须逐列一致")

	# RNG 三条性质：确定性 / 可随机访问 / 每头独立
	var s1 = Rng.stream(Cfg.VERSION_KEY, 999, 1, "layout")
	var s2 = Rng.stream(Cfg.VERSION_KEY, 999, 1, "layout")
	var seq1 := []
	var seq2 := []
	for i in range(16):
		seq1.append(s1.next_u32())
		seq2.append(s2.next_u32())
	t.ok("D4", str(seq1) == str(seq2), "同 key 的流必须给出同序列")

	var h1 = Rng.stream(Cfg.VERSION_KEY, 999, 1, "layout")
	var h2 = Rng.stream(Cfg.VERSION_KEY, 999, 1, "enemy")
	var a1 := []
	var b1 := []
	for i in range(8):
		a1.append(h1.next_u32())
		b1.append(h2.next_u32())
	t.ok("D5", str(a1) != str(b1), "每头必须是独立流（否则加一个头会错位所有旧世界线）")

	# 可随机访问：连续推进 N 次 == 直接从第 N 个子流开始（同 key 重放一致）
	var r_a = Rng.at(Cfg.VERSION_KEY, 999, 1, "layout", 5)
	var r_b = Rng.at(Cfg.VERSION_KEY, 999, 1, "layout", 5)
	t.ok("D6", r_a.next_u32() == r_b.next_u32(), "at(key, index) 必须可随机访问且可重放")

	var dg: String = Dig.fingerprint("dsh-rl")
	t.ok("D7", dg.length() == 16, "指纹应为 16 个 hex 字符，实测 %d" % dg.length())

# --------------------------------------------------------------------------
# E. 机关（单调布尔加 / 不动点 / 关键性）
# --------------------------------------------------------------------------

func check_mechanisms(t, kernel) -> void:
	t.begin("E. 机关：单调布尔加 + 最小不动点（§4.5 / §8）")
	var trial := 4 if quick else 16
	var solved_ok := 0
	var critical_ok := 0
	var gated_ok := 0
	var monotone_ok := 0
	var idem_ok := 0
	var key_reach_ok := 0
	var no_deadlock_ok := 0
	var first_bad := ""
	for si in range(trial):
		var spec = GM.GenSpec.new()
		spec.w = 96
		spec.h = 34
		spec.seed64 = 5150 + si * 31337
		var gen: Dictionary = GM.generate(spec)
		var m = gen["map"]
		var rep = gen["report"]
		var world = GM.place_mechanisms(m, spec, rep)
		var closed = world.base
		var r_closed: Dictionary = closed.reach_from(kernel, closed.spawn, true)
		var sol = world.solve()
		if sol["ok"]:
			solved_ok += 1
		elif first_bad == "":
			first_bad = "seed=%d solve 失败 unreachable=%s trace=%s" % [spec.seed64, str(sol["unreachable"]), str(sol["trace"])]

		# 无死锁：出生点必须能走到**第一个门之前的所有前置条件**
		var key_cell: Vector2i = world.items["key"]
		if r_closed.has(key_cell) or _near2(r_closed, key_cell, 1):
			key_reach_ok += 1
		var m1 = world.mechanisms[0]
		var door1_x: int = m1.pass_cells[0].x
		var near_side_ok := false
		for p in r_closed.keys():
			if p.x < door1_x:
				near_side_ok = true
				break
		if near_side_ok:
			no_deadlock_ok += 1

		# 关键性：库里每个机关都必须真的在把关（进度链：钥匙 → 门1 → 开关 → 门2）
		var crit: Array = world.critical()
		if crit.size() == world.mechanisms.size():
			critical_ok += 1
		elif first_bad == "":
			first_bad = "seed=%d 关键机关 %d/%d（%s）" % [spec.seed64, crit.size(), world.mechanisms.size(), str(crit)]

		# 门真的拦人：不拾取道具时目标不可达（solve(collect=false)）
		var no_collect = world.solve(true, [], false)
		if not no_collect["ok"]:
			gated_ok += 1

		# 单调性：R_关 ⊆ R_开
		var r_open: Dictionary = sol["reach"]
		var subset := true
		for p in r_closed.keys():
			if not r_open.has(p):
				subset = false
				break
		if subset:
			monotone_ok += 1

		# 幂等 / 不动点：再解一次结果相同
		var sol2 = world.solve()
		if str(sol2["opened"]) == str(sol["opened"]) and str(sol2["unreachable"]) == str(sol["unreachable"]):
			idem_ok += 1

	t.ok("E1", solved_ok == trial, "solve 后目标必须可达 %d/%d %s" % [solved_ok, trial, first_bad])
	t.ok("E2", critical_ok == trial, "全部机关都必须是关键机关（进度链无冗余）%d/%d"
		% [critical_ok, trial])
	t.ok("E3", gated_ok == trial, "不拾取道具时目标不可达（门真的在拦人）%d/%d" % [gated_ok, trial])
	t.ok("E4", monotone_ok == trial, "单调性 R_关 ⊆ R_开 %d/%d" % [monotone_ok, trial])
	t.ok("E5", idem_ok == trial, "最小不动点幂等（与触发顺序无关）%d/%d" % [idem_ok, trial])
	t.ok("E6", key_reach_ok == trial, "钥匙必须在出生点可达集内（无死锁）%d/%d"
		% [key_reach_ok, trial])
	t.ok("E7", no_deadlock_ok == trial, "门 1 的出生点侧必须存在可达地面（玩家不会被立刻封死）%d/%d"
		% [no_deadlock_ok, trial])


# --------------------------------------------------------------------------
# G. 楼层布局：33 房 / 机关链 / 门在把关 / 无死锁 / 接口对齐
# --------------------------------------------------------------------------

func check_floors(t, kernel) -> void:
	var trial: int = 3 if quick else 12
	var ok_all := 0
	var first_bad := ""
	var total_ms := 0
	var rooms_total := 0
	var wmax := 0
	var t0 := Time.get_ticks_msec()
	for i in range(trial):
		var seed64: int = 424242 + i * 104729
		for fl in range(1, int(Cfg.RUN["floors"]) + 1):
			var f = Layout.build_floor(Cfg.VERSION_KEY, seed64, fl)
			total_ms += f.gen_ms
			rooms_total += f.rooms.size()
			wmax = maxi(wmax, f.map.w)
			if f.errors.is_empty():
				ok_all += 1
			elif first_bad == "":
				first_bad = "seed=%d floor=%d: %s" % [seed64, fl, str(f.errors)]
	var floors_n: int = trial * int(Cfg.RUN["floors"])
	var ms: int = Time.get_ticks_msec() - t0
	t.ok("G1", ok_all == floors_n, "楼层全部硬约束（G1..G9）通过 %d/%d  %s"
		% [ok_all, floors_n, first_bad])
	t.ok("G2", rooms_total == floors_n * int(Cfg.RUN["rooms_per_floor"]),
		"每层 %d 房，共 %d 房" % [Cfg.RUN["rooms_per_floor"], rooms_total])
	t.info("楼层生成 %d 层：%d ms（平均 %.0f ms/层），最宽 %d 列（%d px）"
		% [floors_n, ms, float(total_ms) / float(floors_n), wmax, wmax * 16])


# --------------------------------------------------------------------------
# H. 六头 + 一局装配：确定性 / 内容约束 / 分布健康度
# --------------------------------------------------------------------------

func check_run(t) -> void:
	var trial: int = 3 if quick else 10
	var ok_all := 0
	var first_bad := ""
	var det_ok := 0
	var fp_ok := 0
	var ms_total := 0
	var enemies := 0
	var rooms := 0
	var arch := {}
	var elite := 0
	var bow := 0
	var bmin := 9999
	var bmax := 0
	for i in range(trial):
		var theta := {}
		for k in Cfg.THETA_KEYS:
			theta[k] = 20 + ((i * 17 + k.length() * 29) % 70)
		var spec = Heads.make_run_spec(700000 + i * 31337, theta)
		var ls = RunGen.build(spec)
		ms_total += ls.gen_ms
		if ls.errors.is_empty():
			ok_all += 1
		elif first_bad == "":
			first_bad = "seed=%d: %s" % [spec.seed64, str(ls.errors)]
		rooms += ls.total_rooms()
		enemies += ls.total_enemies()
		for l in ls.levels:
			for e in l.enemies:
				arch[e.archetype] = int(arch.get(e.archetype, 0)) + 1
				if e.elite:
					elite += 1
			if not l.floor.world.solve()["ok"]:
				bow += 1
		# 确定性：同 spec 重建，指纹必须一致
		var ls2 = RunGen.build(Heads.make_run_spec(spec.seed64, spec.theta))
		if ls2.fingerprint == ls.fingerprint:
			det_ok += 1
		# θ 变化必须真的改变内容（否则 θ 就是个摆设）
		var theta2 := theta.duplicate()
		theta2["combat_density"] = 0 if int(theta["combat_density"]) > 50 else 100
		var ls3 = RunGen.build(Heads.make_run_spec(spec.seed64, theta2))
		if ls3.fingerprint != ls.fingerprint:
			fp_ok += 1
		bmin = mini(bmin, en_ne(ls))
		bmax = maxi(bmax, en_ne(ls))
	t.ok("H1", ok_all == trial, "六头内容约束（X1..X7）全通过 %d/%d  %s" % [ok_all, trial, first_bad])
	t.ok("H2", bow == 0, "每层 BFS 求解出口可达（失败 %d 层）" % bow)
	t.ok("H3", det_ok == trial, "同种子同 θ 必须逐位一致（指纹相同）%d/%d" % [det_ok, trial])
	t.ok("H4", fp_ok == trial, "θ 必须真的改变内容（战斗密度翻转后指纹必须变）%d/%d" % [fp_ok, trial])
	t.ok("H5", bmin >= 4, "每层敌人数量下限（最少 %d 层敌人）" % bmin)
	t.ok("H6", arch.size() >= 6, "八类原型至少用到 6 类（实际 %d 类：%s）"
		% [arch.size(), str(arch.keys())])
	t.ok("H7", elite >= trial, "精英必须出现（%d 只）" % elite)
	t.info("一局装配 %d 局：%d 房 / %d 敌人（精英 %d）；平均 %d ms/局；每层敌人 %d~%d"
		% [trial, rooms, enemies, elite, int(ms_total / trial), bmin, bmax])

func en_ne(ls) -> int:
	var n := 0
	for l in ls.levels:
		n += l.enemies.size()
	return n


## 半径 r 的邻域命中（与 World._near 同语义）
func _near2(reach: Dictionary, cell: Vector2i, r: int) -> bool:
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			if reach.has(Vector2i(cell.x + dx, cell.y + dy)):
				return true
	return false

# --------------------------------------------------------------------------
# F. 房间模板：门段 / 不变量 B / 双向可达 / 内容槽可达 / 无底部后门
# --------------------------------------------------------------------------

func check_rooms(t, kernel) -> void:
	var trial: int = 24 if quick else 200
	var ok_all := 0
	var slot_min := 99999
	var slot_total := 0
	var gallery_ok := 0
	var gallery_n := 0
	var fps := {}
	var first_bad := ""
	var t0 := Time.get_ticks_msec()
	for i in range(trial):
		var spec = Room.RoomSpec.new()
		spec.rid = "r%d" % i
		spec.w = 48 + (i % 4) * 6          # 48 / 54 / 60 / 66
		spec.h = 34
		spec.seed64 = 90001 + i * 7919
		spec.version_key = Cfg.VERSION_KEY
		spec.entry_row = 22 + (i % 3)
		spec.exit_row = 22 + ((i + 1) % 3)
		spec.with_gallery = (i % 3) != 2
		spec.platform_budget = 2 + (i % 3)
		var v = Room.build(spec)
		if v.errors.is_empty():
			ok_all += 1
		elif first_bad == "":
			first_bad = "i=%d w=%d: %s" % [i, spec.w, str(v.errors)]
		slot_min = mini(slot_min, v.slot_count())
		slot_total += v.slot_count()
		if spec.with_gallery:
			gallery_n += 1
			if not v.gallery_cells.is_empty():
				gallery_ok += 1
		fps[v.fingerprint()] = true
	var ms: int = Time.get_ticks_msec() - t0
	t.ok("F1", ok_all == trial, "房间全部不变量（R1..R5）通过 %d/%d  %s" % [ok_all, trial, first_bad])
	t.ok("F2", slot_min >= 6, "内容槽不少于 6 个（最少 %d，平均 %.1f）"
		% [slot_min, float(slot_total) / float(trial)])
	t.ok("F3", gallery_ok == gallery_n, "带上层平台的房间必须真的生成出上层长廊 %d/%d"
		% [gallery_ok, gallery_n])
	t.ok("F4", fps.size() >= trial - 1, "不同种子必须生成出不同房间（指纹去重 %d/%d）"
		% [fps.size(), trial])
	t.info("房间生成 %d 张：%d ms（平均 %.2f ms/张）" % [trial, ms, float(ms) / float(trial)])
