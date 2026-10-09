extends SceneTree
## probe13 —— 第 3 层 BOSS 验收：有没有生成、三阶段会不会翻面、阶段事件有没有记。
##
## 用法：--seed=3000 [--floor=3]

const Cfg = preload("res://core/constants.gd")
const RunState = preload("res://run/run_state.gd")

func _init() -> void:
	var seed64: int = int(Cfg.cmdline_value("--seed", "3000"))
	var fi: int = int(Cfg.cmdline_value("--floor", "3"))
	var run = RunState.new(seed64, false)
	run.generate()
	run.start_floor(fi)
	var lv = run.level
	var boss = null
	for a in lv.actors:
		if a.kind == "enemy" and a.archetype == "boss":
			boss = a
	print("层=%d 敌人=%d boss_spawned=%s" % [fi, lv.actors.size(), str(lv.boss_spawned)])
	if boss == null:
		print("✗ 这一层没有 BOSS")
		quit()
		return
	print("BOSS: hp=%d/%d weight=%s super_armor=%s 位置=(%.0f,%.0f) 精英=%s"
		% [boss.hp, boss.max_hp, boss.weight, str(boss.super_armor), boss.p.x, boss.p.y, str(boss.elite)])
	# 逐步削血，看阶段事件
	var phases: Array = []
	var step_dmg: int = maxi(1, int(boss.max_hp / 90))
	var f := 0
	while boss.alive and boss.hp > 1 and f < 4000:
		f += 1
		boss.hp -= step_dmg
		lv.step({})
		for e in lv.events:
			if e.kind == "boss_phase" and not phases.has(int(e.data.get("phase", 0))):
				phases.append(int(e.data.get("phase", 0)))
				print("  阶段事件：phase=%d hp=%d 第 %d 帧" % [int(e.data.get("phase", 0)), int(e.data.get("hp", -1)), lv.frame])
		if not boss.alive:
			break
	print("阶段序列=%s（期望 [2, 3]）" % str(phases))
	print("击杀后敌人数=%d 玩家 hp=%d" % [_alive(lv), lv.player.hp])
	quit()

func _alive(lv) -> int:
	var n := 0
	for a in lv.actors:
		if a.kind == "enemy" and a.alive:
			n += 1
	return n
