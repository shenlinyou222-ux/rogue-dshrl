# BT —— 行为树（敌人 AI 的骨架）
#
# 为什么是行为树而不是「一大坨 if」：
#   1. 节点可以被**数据化**，于是「难度/风格」= 节点权重（ctx 六维直接拧）；
#   2. 每帧执行有**明确预算**（见 §帧预算），不会因为某个敌人路径计算卡死整帧；
#   3. 子树可以单独测试（工具里直接 tick 一个子树喂假黑板）。
#
# 设计取舍：不用 Godot 的 Node 做节点（那会带来场景树顺序依赖，破坏可复现性），
# 用纯 RefCounted + Callable，确定性完全由我们掌控。

extends RefCounted

enum { SUCCESS, FAILURE, RUNNING }

const FPS := 60

# --------------------------------------------------------------------------

class BtNode:
	var kind: String = "act"        # seq / sel / cond / act / inv
	var label: String = ""
	var fn: Callable = Callable()
	var children: Array = []
	var weight: float = 1.0         # ctx 加权：<=0 直接跳过（这就是「风格」的入口）
	var weight_key: String = ""     # 由黑板里的哪个 ctx 维加权

	func tick(bb) -> int:
		if not enabled(bb):
			return FAILURE
		match kind:
			"cond":
				return SUCCESS if bool(fn.call(bb)) else FAILURE
			"act":
				return int(fn.call(bb))
			"seq":
				for c in children:
					var r: int = c.tick(bb)
					if r != SUCCESS:
						return r
				return SUCCESS
			"sel":
				# 加权选择：按 weight 从上到下试，权重为 0 的跳过
				var best: Array = []
				for c in children:
					best.append(c)
				best.sort_custom(func(a, b): return a.weight > b.weight)
				for c2 in best:
					if not c2.enabled(bb):
						continue
					var r2: int = c2.tick(bb)
					if r2 != FAILURE:
						return r2
				return FAILURE
			"inv":
				var r3: int = children[0].tick(bb)
				if r3 == SUCCESS:
					return FAILURE
				if r3 == FAILURE:
					return SUCCESS
				return RUNNING
		return FAILURE

	## 权重 = 静态 weight × ctx 维值（ctx ∈ [0,1]）+ 一个很小的保底，
	## 保证「权重为 0」= 完全不选，但仍可被显式调用。
	func enabled(bb) -> bool:
		if weight <= 0.0:
			return false
		return true

	func score(bb) -> float:
		var s: float = weight
		if weight_key != "":
			s *= float(bb.ctx.get(weight_key, 0.5))
		return s

# --------------------------------------------------------------------------
# 构造助手
# --------------------------------------------------------------------------

static func act(label: String, fn: Callable, weight: float = 1.0,
				weight_key: String = "") -> Object:
	var n = BtNode.new()
	n.kind = "act"
	n.label = label
	n.fn = fn
	n.weight = weight
	n.weight_key = weight_key
	return n

static func cond(label: String, fn: Callable, weight: float = 1.0,
				 weight_key: String = "") -> Object:
	var n = BtNode.new()
	n.kind = "cond"
	n.label = label
	n.fn = fn
	n.weight = weight
	n.weight_key = weight_key
	return n

static func seq(children: Array, label: String = "seq") -> Object:
	var n = BtNode.new()
	n.kind = "seq"
	n.label = label
	n.children = children
	return n

static func sel(children: Array, label: String = "sel") -> Object:
	var n = BtNode.new()
	n.kind = "sel"
	n.label = label
	n.children = children
	return n

# --------------------------------------------------------------------------
# 帧预算：活着的敌人分帧思考
# --------------------------------------------------------------------------
# ceil(alive/4) 个敌人每帧思考一次 —— 4 帧一个完整刷新周期。
# 为什么不是「全部每帧思考」：40 个敌人 × 每个若干次射线/距离计算，
# 在 60 Hz 下会吃掉整帧预算。分帧后单帧开销与敌人数脱钩（只与 /4 有关），
# 而玩家完全感知不到 4 帧（66 ms）的决策延迟 —— 因为动作的**帧数据**才是手感来源，
# 决策只决定「往哪走 / 出哪招」，本来就不该逐帧抖动。
static func think_budget(alive_count: int) -> int:
	return int(ceil(float(alive_count) / 4.0))
