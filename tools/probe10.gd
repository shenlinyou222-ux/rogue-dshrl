extends SceneTree
## probe10 —— 「进度物到底在不在可达区里」定位器
##
## 为什么需要它：生成层的可达性用的是运动核 K 的**宽松掩码**
## （只把"上下都实心"的格算墙，天花板不算墙），而运行时碰撞把任何阻挡格都算墙。
## 于是存在一种致命情况：钥匙/开关被放进一个**只有穿过天花板才到得了**的封死空腔，
## 生成期验证会说"可达"，真人玩家却永远拿不到 —— 关卡直接不可通关。
##
## 本探测器用**严格掩码**（与运行时一致）分别算：
##   F = 出生格能走到的全部站立格
##   B  = 能走到终点的全部站立格
## 然后检查关键格（钥匙/开关/终点）是否同时落在 F 和 B 里。

const Cfg = preload("res://core/constants.gd")
const Layout = preload("res://gen/layout.gd")
const MK = preload("res://gen/motion_kernel.gd")
const VM = preload("res://gen/voxel_map.gd")

func _init() -> void:
	var s0: int = int(Cfg.cmdline_value("--seed", "3000"))
	var n: int = int(Cfg.cmdline_value("--count", "6"))
	var strict: bool = Cfg.cmdline_value("--strict", "1") != "0"
	var kernel = MK.get_kernel()
	print("%s掩码可达性检查：%d 个种子 × 3 层" % ["严格" if strict else "宽松", n])
	var bad := 0
	var total := 0
	for i in range(n):
		var seed64: int = s0 + i * 977
		for fi in range(1, 4):
			var f = Layout.build_floor(Cfg.VERSION_KEY, seed64, fi, false)
			var m = f.base
			var open_m = m.clone()
			var doors: Array = []
			for y in range(m.h):
				var row: String = m.cells[y]
				for x in range(m.w):
					if row[x] == VM.DOOR:
						doors.append(Vector2i(x, y))
			if not doors.is_empty():
				open_m = m.open_cells(doors)
			var ff: Dictionary = open_m.reach_from(kernel, m.spawn, false, strict)
			var bb: Dictionary = open_m.reach_back_from(kernel, m.goal, strict)
			total += 1
			var probs: Array = []
			if not ff.has(m.goal):
				probs.append("终点不在 F 里")
			if not ff.has(m.spawn):
				probs.append("出生点不在 F 里(!)")
			if f.key_cell.x >= 0 and not ff.has(f.key_cell):
				probs.append("钥匙 %s 不可达" % str(f.key_cell))
			if f.key_cell.x >= 0 and not bb.has(f.key_cell):
				probs.append("钥匙 %s 到不了终点" % str(f.key_cell))
			if f.switch_cell.x >= 0 and not ff.has(f.switch_cell):
				probs.append("开关 %s 不可达" % str(f.switch_cell))
			if f.switch_cell.x >= 0 and not bb.has(f.switch_cell):
				probs.append("开关 %s 到不了终点" % str(f.switch_cell))
			if not probs.is_empty():
				bad += 1
				print("  ✗ seed=%d 层=%d w=%d | %s" % [seed64, fi, m.w, ", ".join(probs)])
	print("--- 检查 %d 层：有问题 %d 层 ---" % [total, bad])
	quit()
