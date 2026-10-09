# Rng —— 确定性整数随机流
#
# 设计约束（来自 机制拆解 §3.1 / 地图方案 §9，三条都必须满足）：
#   1. **全整数**：不出现浮点随机，跨进程字节一致；
#   2. **可随机访问**：`at(key, index)` 能直接跳到流的第 index 个数，
#      不需要从头推进（世界线变体、分头独立流都靠这条）；
#   3. **每头独立流**：六头各自一条流，互不干扰（否则加一个头就会
#      把其它头的输出全部错位，旧世界线全碎）。
#
# 实现：splitmix32（32 位运算，Godot int64 承载，全程掩码到 32 位）。
#
# 原型用的是手写 ChaCha20（GDScript 版空载 19 ms/层，是性能瓶颈），
# 文档明确允许换成更快的整数流，但**必须保持上面三条性质**。

extends RefCounted

const Dig = preload("res://core/digest.gd")
const MASK32 := 0xFFFFFFFF
const GOLDEN32 := 0x9E3779B9

var _state: int = 0

func _init(seed32: int = 0) -> void:
	_state = seed32 & MASK32

# --------------------------------------------------------------------------
# 构造
# --------------------------------------------------------------------------

## 从 64 位种子建流（取低 32 位 + 高位混合，避免只用低位的相关性）。
static func from_seed(seed64: int) -> RefCounted:
	var lo := seed64 & MASK32
	var hi := (seed64 >> 32) & MASK32
	var s := Dig.mix32(lo ^ Dig.mix32(hi + GOLDEN32))
	var r = load("res://core/rng.gd").new(s)
	return r

## 每头独立流：Key = (版本键, 种子, 楼层, 头名, 附加标签)。
## 这是"失败重试必须推进流"的实现方式 —— 附加标签里带重试计数。
static func stream(version_key: String, seed64: int, floor: int, head: String,
				   tag: String = "") -> RefCounted:
	var key := "%s|%d|%d|%s|%s" % [version_key, seed64, floor, head, tag]
	var r = load("res://core/rng.gd").new(Dig.h32(key))
	return r

## 可随机访问：直接取 (stream_key, index) 处的流状态。
## index 语义 = "这条流的第 index 个子流"，用于"按房间/按列"派生，
## 从而让生成过程与遍历顺序解耦。
static func at(version_key: String, seed64: int, floor: int, head: String, index: int) -> RefCounted:
	return stream(version_key, seed64, floor, head, "i%d" % index)

## 从当前流派生子流（确定性 fork，不影响父流后续输出）。
func fork(tag: String) -> RefCounted:
	var probe := "%s#%d#%d" % [tag, _state, peek()]
	var r = load("res://core/rng.gd").new(Dig.h32(probe))
	return r

# --------------------------------------------------------------------------
# 推进与取值
# --------------------------------------------------------------------------

## 下一个 32 位无符号数（splitmix32）。
func next_u32() -> int:
	_state = (_state + GOLDEN32) & MASK32
	var z := _state
	z = ((z ^ (z >> 16)) * 0x21F0AAAD) & MASK32
	z = ((z ^ (z >> 15)) * 0x735A2D97) & MASK32
	return (z ^ (z >> 15)) & MASK32

## 不推进流的当前值（诊断用）。
func peek() -> int:
	var saved := _state
	var v := next_u32()
	_state = saved
	return v

## [0, n) 上的整数。n <= 0 时返回 0。
## 用 multiply-shift 而不是取模：无偏且开销恒定。
func range_i(n: int) -> int:
	if n <= 0:
		return 0
	if n == 1:
		return 0
	return (next_u32() * n) >> 32

## [lo, hi] 闭区间整数。
func range_lo_hi(lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	return lo + range_i(hi - lo + 1)

## 百分比概率（0~100）。
func chance(percent: int) -> bool:
	if percent <= 0:
		return false
	if percent >= 100:
		return true
	return range_i(100) < percent

## 从数组里挑一个（返回 null 表示空数组）。
func pick(arr: Array):
	if arr.is_empty():
		return null
	return arr[range_i(arr.size())]

## 加权挑选：weights 与 items 等长。权重必须 >= 0。
func pick_weighted(items: Array, weights: Array):
	var total := 0
	for w in weights:
		total += max(0, int(w))
	if total <= 0:
		return pick(items)
	var roll := range_i(total)
	var acc := 0
	for i in range(items.size()):
		acc += max(0, int(weights[i]))
		if roll < acc:
			return items[i]
	return items[items.size() - 1]

## 确定性 Fisher-Yates（原地打乱副本）。
func shuffle(arr: Array) -> Array:
	var a := arr.duplicate()
	for i in range(a.size() - 1, 0, -1):
		var j := range_i(i + 1)
		var tmp = a[i]
		a[i] = a[j]
		a[j] = tmp
	return a

## 按权重分布抽稀有度索引（掉落曲线）。
func pick_rarity(curve: Array) -> int:
	var weights := []
	for p in curve:
		weights.append(int(round(float(p) * 10000.0)))
	var idx = pick_weighted(range(curve.size()), weights)
	return int(idx)

# --------------------------------------------------------------------------
# 状态存取（回放/存档/重演）
# --------------------------------------------------------------------------

func get_state() -> int:
	return _state

func set_state(s: int) -> void:
	_state = s & MASK32
