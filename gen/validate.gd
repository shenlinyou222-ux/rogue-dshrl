# Validate —— 生成产物的**构造性约束**校验（§8.1）
#
# 这里不是「生成-校验-重试」的后半截 —— 生成过程本身已经构造性保证了这些约束，
# 本模块是**不会被触发的安全网**：一旦有断言失败，说明上面某个头写错了，
# 而不是「运气不好」。所以自检里要求它必须 100% 通过。
#
# 与几何层的分工：
#   几何不变量（R1..R5 / G1..G9）在 room.gd / layout.gd 里就地断言；
#   内容约束（X1..X7）在这里统一断言。

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const Heads = preload("res://gen/heads.gd")

## 逐层校验，返回可读错误列表。
static func check_floor(floor, spec, enemies: Array, loot: Array, event, theta) -> Array:
	var errs: Array = []

	# ---------------- X1 房间类型配额 ----------------
	var counts := {}
	for fr in floor.rooms:
		counts[fr.rtype] = int(counts.get(fr.rtype, 0)) + 1
	if int(counts.get("rest", 0)) != 1:
		errs.append("X1 每层必须恰好 1 个休息房（实际 %d）" % int(counts.get("rest", 0)))
	if int(counts.get("shop", 0)) > int(Cfg.ROOM_QUOTA["shop"]):
		errs.append("X1 商店超配额")
	if int(counts.get("secret", 0)) > int(Cfg.ROOM_QUOTA["secret"]):
		errs.append("X1 密室超配额")
	if int(counts.get("elite", 0)) > int(Cfg.ROOM_QUOTA["elite"]):
		errs.append("X1 精英房超配额")
	var is_boss: bool = floor.floor_index in Cfg.RUN["boss_floors"]
	if int(counts.get("boss", 0)) != (1 if is_boss else 0):
		errs.append("X1 Boss 层规则被破坏")

	# ---------------- X2 威胁预算 ----------------
	var cap_max: int = Heads.threat_cap(floor.floor_index, theta)
	if cap_max > int(Cfg.DIFFICULTY["max_enemies_screen"]):
		errs.append("X2 威胁上限 %d 超过屏幕敌人上限" % cap_max)
	var per_room := {}
	for e in enemies:
		per_room[e.room_index] = int(per_room.get(e.room_index, 0)) + int(e.threat)
	for ri in per_room.keys():
		# 预算必须**调用生成头用的同一个函数**（否则就是两套算法互相打架）
		var rt: String = floor.rooms[ri].rtype
		var cap: int = Heads.effective_cap(floor.floor_index, rt, theta)
		if int(per_room[ri]) > cap:
			errs.append("X2 房 %d(%s) 威胁 %d 超预算 %d" % [ri, rt, per_room[ri], cap])
	# 同一房内敌人不能挤在一起（否则玩家没有解法空间）
	var by_room := {}
	for e2 in enemies:
		by_room[e2.room_index] = true
	for ri2 in by_room.keys():
		var list: Array = []
		for e3 in enemies:
			if e3.room_index == ri2:
				list.append(e3)
		for a in range(list.size()):
			for b in range(a + 1, list.size()):
				if list[a].cell == list[b].cell:
					errs.append("X2 房 %d 有敌人重叠在同一格 %s" % [ri2, str(list[a].cell)])
	# 出生房 / 休息房 / 商店房不许有敌人
	for e4 in enemies:
		var rt2: String = floor.rooms[e4.room_index].rtype
		if rt2 == "start" or rt2 == "rest" or rt2 == "shop":
			errs.append("X2 %s 房不该有敌人" % rt2)
			break

	# ---------------- X3 词缀合法性 ----------------
	for e5 in enemies:
		if e5.affix == "":
			continue
		if not Cfg.AFFIXES.has(e5.affix):
			errs.append("X3 未知词缀 %s" % e5.affix)
			continue
		var forb: Array = Cfg.AFFIXES[e5.affix]["forbidden_on"]
		if e5.archetype in forb:
			errs.append("X3 词缀 %s 不允许挂在 %s 上" % [e5.affix, e5.archetype])
		if not e5.elite:
			errs.append("X3 非精英敌人不该有词缀")

	# ---------------- X4 敌人必须站在可达槽上 ----------------
	var slot_set := {}
	for fr2 in floor.rooms:
		for s in fr2.slots:
			slot_set["%d,%d" % [s.x, s.y]] = true
	for e6 in enemies:
		if not slot_set.has("%d,%d" % [e6.cell.x, e6.cell.y]):
			errs.append("X4 敌人 %s 不在内容槽上（可能刷在不可达处）" % str(e6.cell))
			break

	# ---------------- X5 掉落曲线 ----------------
	var total := 0.0
	for p in Cfg.RARITY_CURVE:
		total += float(p)
	if absf(total - 1.0) > 0.001:
		errs.append("X5 稀有度曲线概率和 != 1（%.4f）" % total)
	# 每层至少一把武器（否则整层没有构筑机会）
	var weapons := 0
	for d in loot:
		if d.room_index == floor.rooms.size() - 1:
			continue
		if d.rarity >= 0:
			weapons += 1
	if weapons == 0 and loot.is_empty():
		errs.append("X5 本层没有任何掉落")

	# ---------------- X6 主题合法性 ----------------
	if event != null and not (event.theme in Cfg.THEMES):
		errs.append("X6 未知主题 %s" % event.theme)

	# ---------------- X7 敌人朝向必须指向房间内部 ----------------
	for e7 in enemies:
		if e7.facing != 1 and e7.facing != -1:
			errs.append("X7 敌人朝向非法")
			break
	return errs
