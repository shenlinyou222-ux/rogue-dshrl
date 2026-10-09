# VoxelMap —— 体素矩阵（内容层 + 碰撞层）
#
# 唯一真相模型（地图方案 §4.5）：
#
#   cells[y][x]   : 字符      . S G K D d B ^
#   blocked[y][x] : bool      -- 机关 = 单纯翻转这里的位
#   walk          = ¬blocked ∧ blocked(y+1, x)     「站着」= 脚下那一格是实心
#   A = walk ⊗ K   （形态学膨胀：查核表 + 轨迹掩码，没有任何物理计算）
#   R = A*         （布尔闭包；BFS ≡ Warshall）
#
# 三条踩过的坑，写死在代码里：
#   1. **地图最后一行不算地面** —— 否则任何「空到底」的竖井都会在底行冒出
#      一排可站立格，形成一条平行通道，把所有墙类机关变成装饰品。
#   2. **危险格（尖刺）算可站立** —— 尖刺是「踩了掉血」，不是「过不去」。
#   3. **轨迹检查里只有「上下都实心」的格才是墙** —— 地面（上面是空的）
#      与浮空平台（下面是空的）都不是墙，否则一步都走不动。

extends RefCounted

const Cfg = preload("res://core/constants.gd")
const Dig = preload("res://core/digest.gd")

const SOLID := "#"
const EMPTY := "."
const SPAWN := "S"
const GOAL := "G"
const KEY := "K"
const DOOR := "D"          # 关闭的门（阻挡）
const DOOR_OPEN := "d"     # 打开的门（通行）
const SWITCH := "B"
const DANGER := "^"
const BLOCKING := "#D"     # DOOR 必须在这里，否则机关系统就是装饰品

var w: int = 0
var h: int = 0
var cells: PackedStringArray = PackedStringArray()
var blocked: PackedByteArray = PackedByteArray()
var spawn: Vector2i = Vector2i(-1, -1)
var goal: Vector2i = Vector2i(-1, -1)

var _wall: PackedByteArray = PackedByteArray()
var _wall_ready := false

## 站立格判定（生成期/工具通用）：
##   本格不挡 ∧ 脚下是实心 ∧ **头顶 2 行空**
## 头顶判据是"捕鼠笼"事故后加的：玩家高 28px（占 2 行），要跳出一格台阶还得再要 1 行。
## 生成期的房间 R6 与无头机器人（tools/sim.gd）共用同一条规则，避免两边定义漂移。
func blocked_at(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= w or y >= h:
		return true
	return blocked[y * w + x] == 1

func walkable(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= w or y >= h:
		return false
	if blocked[y * w + x] == 1:
		return false
	if y + 1 >= h or blocked[(y + 1) * w + x] == 0:
		return false
	if y - 1 < 0 or blocked[(y - 1) * w + x] == 1:
		return false
	return y - 2 >= 0 and blocked[(y - 2) * w + x] == 0

# --------------------------------------------------------------------------
# 构造
# --------------------------------------------------------------------------

func _init(cell_rows: PackedStringArray = PackedStringArray(),
		   blocked_pack: PackedByteArray = PackedByteArray(),
		   spawn_cell: Vector2i = Vector2i(-1, -1),
		   goal_cell: Vector2i = Vector2i(-1, -1)) -> void:
	if cell_rows.is_empty():
		return
	cells = cell_rows
	h = cells.size()
	w = cells[0].length()
	for r in cells:
		if r.length() != w:
			push_error("矩阵行宽不一致")
	if blocked_pack.is_empty():
		blocked = PackedByteArray()
		blocked.resize(w * h)
		for y in range(h):
			var row := cells[y]
			for x in range(w):
				blocked[y * w + x] = 1 if BLOCKING.contains(row[x]) else 0
	else:
		blocked = blocked_pack
	spawn = spawn_cell
	goal = goal_cell
	if spawn.x < 0 or goal.x < 0:
		_locate()

## 用行数据重建 cells/blocked（生成后修补用，例如陷阱剪除）
func apply_rows(rows: PackedStringArray) -> void:
	cells = rows
	h = cells.size()
	w = cells[0].length()
	blocked = PackedByteArray()
	blocked.resize(w * h)
	for y in range(h):
		var row := cells[y]
		for x in range(w):
			blocked[y * w + x] = 1 if BLOCKING.contains(row[x]) else 0
	_wall_ready = false

func _locate() -> void:	for y in range(h):
		var row := cells[y]
		for x in range(w):
			var c := row[x]
			if c == SPAWN and spawn.x < 0:
				spawn = Vector2i(x, y)
			elif c == GOAL and goal.x < 0:
				goal = Vector2i(x, y)

## 从字符串数组（可读）构造。行可以是 String 或逐字符的 PackedStringArray。
static func from_strings(rows: Array) -> RefCounted:
	var ps := PackedStringArray()
	for r in rows:
		if typeof(r) == TYPE_PACKED_STRING_ARRAY:
			var s := ""
			for c in r:
				s += str(c)
			ps.append(s)
		else:
			ps.append(str(r))
	return load("res://gen/voxel_map.gd").new(ps)

## 把 PackedStringArray（每行一个不可变 String）转成**可逐格改写**的行数组。
##
## 为什么必须有这个函数：GDScript 的 String 是不可变的，`row[i] = "#"` 无效。
## 生成器需要按格改写地形，所以内部一律用 Array[PackedStringArray]（一格一个元素）；
## 只有进出 VoxelMap 时才折成 String。这一条曾经静默吃掉过所有机关封列操作
## （门根本没被封上，机关全判冗余）。
static func mutable_rows(ps: PackedStringArray) -> Array:
	var out: Array = []
	for r in ps:
		var row := PackedStringArray()
		row.resize(r.length())
		for i in range(r.length()):
			row[i] = r[i]
		out.append(row)
	return out

## 常见字符常量
static func ch_solid() -> String:
	return SOLID

# --------------------------------------------------------------------------
# 基本访问
# --------------------------------------------------------------------------

func idx(x: int, y: int) -> int:
	return y * w + x

func at(x: int, y: int) -> String:
	if x < 0 or x >= w or y < 0 or y >= h:
		return SOLID                 # 越界当实心，避免「跳出地图」这种退化
	return cells[y][x]

func is_blocked(x: int, y: int) -> bool:
	if x < 0 or x >= w or y < 0 or y >= h:
		return true
	return blocked[y * w + x] == 1

## 可站立格点：本格不阻挡、且下方一格实心。
## **地图最后一行不算地面**（见文件头坑 1）。
func standable(x: int, y: int) -> bool:
	if is_blocked(x, y):
		return false
	return is_blocked(x, y + 1)

func nodes() -> Array:
	var out: Array = []
	for y in range(h):
		for x in range(w):
			if standable(x, y):
				out.append(Vector2i(x, y))
	return out

func node_set() -> Dictionary:
	var out := {}
	for p in nodes():
		out[p] = true
	return out

# --------------------------------------------------------------------------
# 轨迹「墙」判定（三段式：只认上下都实心的岩体/门）
# --------------------------------------------------------------------------

func _build_wall() -> void:
	_wall = PackedByteArray()
	_wall.resize(w * h)
	for y in range(h):
		for x in range(w):
			if blocked[y * w + x] == 0:
				continue
			var above: bool = y > 0 and blocked[(y - 1) * w + x] == 1
			var below: bool = (y + 1 >= h) or blocked[(y + 1) * w + x] == 1
			if above and below:
				_wall[y * w + x] = 1
	_wall_ready = true

func is_wall(x: int, y: int) -> bool:
	if not _wall_ready:
		_build_wall()
	if x < 0 or x >= w:
		# 越界：is_blocked=true；above = (y>0) 且越界也算实心；below=true
		return y > 0
	if y < 0:
		return false
	if y >= h:
		if y - 1 >= h:
			return true
		return blocked[(y - 1) * w + x] == 1
	return _wall[y * w + x] == 1

# --------------------------------------------------------------------------
# 图：邻接与可达（矩阵膨胀 + 布尔闭包）
#
# 性能：把 walk / wall 两张表**预计算成带外圈填充的扁平数组**，
# 于是膨胀与轨迹检查退化成纯数组下标运算（没有函数调用、没有边界分支）。
# 这是让「生成期反复调用可达性」可行的关键 —— 单张 96x34 图的 BFS 从
# 秒级降到毫秒级。
# --------------------------------------------------------------------------

var _stride: int = 0
var _pad_x: int = 0
var _pad_y: int = 0
var _pwalk: PackedByteArray = PackedByteArray()
var _pwall: PackedByteArray = PackedByteArray()
var _pblk: PackedByteArray = PackedByteArray()   # 任意阻挡格（= 运行时碰撞判据）
var _prepared_for = null

func prepare(kernel) -> void:
	if _prepared_for == kernel and not _pwalk.is_empty():
		return
	if not _wall_ready:
		_build_wall()
	var mx := 1
	var my := 1
	for off in kernel.cells:
		mx = maxi(mx, absi(off.x))
		my = maxi(my, absi(off.y))
		for rel in kernel.mask_of(off):
			mx = maxi(mx, absi(rel.x))
			my = maxi(my, absi(rel.y))
	_pad_x = mx + 1
	_pad_y = my + 1
	_stride = w + 2 * _pad_x
	var rows := h + 2 * _pad_y
	_pwalk = PackedByteArray()
	_pwalk.resize(_stride * rows)
	_pwall = PackedByteArray()
	_pwall.resize(_stride * rows)
	_pblk = PackedByteArray()
	_pblk.resize(_stride * rows)
	for yy in range(-_pad_y, h + _pad_y):
		var rowbase := (yy + _pad_y) * _stride
		for xx in range(-_pad_x, w + _pad_x):
			var i := rowbase + xx + _pad_x
			_pwalk[i] = 1 if standable(xx, yy) else 0
			_pwall[i] = 1 if is_wall(xx, yy) else 0
			_pblk[i] = 1 if blocked_at(xx, yy) else 0
	_prepared_for = kernel

## A = walk ⊗ K：可站立格点矩阵被运动核膨胀。
## 第三个条件（轨迹不穿墙）是必需的 —— 少了它，长距离偏移会让玩家穿墙。
func adjacency(kernel, forward_only: bool = true,
			   check_trajectory: bool = true) -> Dictionary:
	prepare(kernel)
	var adj := {}
	var offs: Array = kernel.cells
	var st := _stride
	var pdx := _pad_x
	var pdy := _pad_y
	for y in range(h):
		for x in range(w):
			if _pwalk[(y + pdy) * st + x + pdx] == 0:
				continue
			var nbrs: Array = []
			var bx := x + pdx
			var by := y + pdy
			for off in offs:
				if forward_only and off.x < 0:
					continue
				if _pwalk[(by + off.y) * st + bx + off.x] == 0:
					continue
				if check_trajectory:
					var blocked_path := false
					for rel in kernel.mask_of(off):
						if _pwall[(by + rel.y) * st + bx + rel.x] == 1:
							blocked_path = true
							break
					if blocked_path:
						continue
				nbrs.append(Vector2i(x + off.x, y + off.y))
			adj[Vector2i(x, y)] = nbrs
	return adj

## 从 start 出发的可达集（有向 BFS）。
func reach_from(kernel, start: Vector2i, forward_only: bool = true, strict_mask: bool = false) -> Dictionary:
	prepare(kernel)
	if not standable(start.x, start.y):
		return {}
	var offs: Array = kernel.cells
	var st := _stride
	var pdx := _pad_x
	var pdy := _pad_y
	var pw := _pwalk
	var pwl := _pblk if strict_mask else _pwall
	var visited := {start: true}
	var stack: Array = [start]
	while not stack.is_empty():
		var p: Vector2i = stack.pop_back()
		var bx: int = p.x + pdx
		var by: int = p.y + pdy
		for off in offs:
			if forward_only and off.x < 0:
				continue
			if pw[(by + off.y) * st + bx + off.x] == 0:
				continue
			var q := Vector2i(p.x + off.x, p.y + off.y)
			if visited.has(q):
				continue
			var bad := false
			for rel in kernel.mask_of(off):
				if pwl[(by + rel.y) * st + bx + rel.x] == 1:
					bad = true
					break
			if bad:
				continue
			visited[q] = true
			stack.append(q)
	return visited

## 反向可达：所有**能走到 target** 的站立格（把步长取反做 BFS）。
## 用途 = 剪掉「陷阱区」：能走进去、但进去之后再也到不了目标的地方。
## 例：站在上层长廊正下方的凹槽里，头顶被长廊堵死、前面一格台阶比头还高 ——
##     真人玩家走进去就出不来了（无头机器人实测踩到过，6/6 局卡死）。
func reach_back_from(kernel, target: Vector2i, strict_mask: bool = false) -> Dictionary:
	prepare(kernel)
	if not standable(target.x, target.y):
		return {}
	var offs: Array = kernel.cells
	var st := _stride
	var pdx := _pad_x
	var pdy := _pad_y
	var pw := _pwalk
	var pwl := _pblk if strict_mask else _pwall
	var visited := {target: true}
	var stack: Array = [target]
	while not stack.is_empty():
		var q: Vector2i = stack.pop_back()
		for off in offs:
			var p := Vector2i(q.x - off.x, q.y - off.y)
			if visited.has(p) or not standable(p.x, p.y):
				continue
			var bx: int = p.x + pdx
			var by: int = p.y + pdy
			if pw[(by + off.y) * st + bx + off.x] == 0:
				continue
			var bad := false
			for rel in kernel.mask_of(off):
				if pwl[(by + rel.y) * st + bx + rel.x] == 1:
					bad = true
					break
			if bad:
				continue
			visited[p] = true
			stack.append(p)
	return visited

## 有向最短步数 BFS（-1 表示不可达）。「抄近路收益」用它。
func bfs_dist(kernel, src: Vector2i, dst: Vector2i, forward_only: bool = true) -> int:
	prepare(kernel)
	if not standable(src.x, src.y):
		return -1
	var offs: Array = kernel.cells
	var st := _stride
	var pdx := _pad_x
	var pdy := _pad_y
	var pw := _pwalk
	var pwl := _pwall
	var seen := {src: 0}
	var queue: Array = [src]
	var qi := 0
	while qi < queue.size():
		var p: Vector2i = queue[qi]
		qi += 1
		if p == dst:
			return int(seen[p])
		var d: int = int(seen[p]) + 1
		var bx: int = p.x + pdx
		var by: int = p.y + pdy
		for off in offs:
			if forward_only and off.x < 0:
				continue
			if pw[(by + off.y) * st + bx + off.x] == 0:
				continue
			var q := Vector2i(p.x + off.x, p.y + off.y)
			if seen.has(q):
				continue
			var bad := false
			for rel in kernel.mask_of(off):
				if pwl[(by + rel.y) * st + bx + rel.x] == 1:
					bad = true
					break
			if bad:
				continue
			seen[q] = d
			queue.append(q)
	return -1

## 无向可达（把边补成对称），用于「这张图连通吗」。
func reach_from_undirected(kernel, start: Vector2i) -> Dictionary:
	var adj := adjacency(kernel, false, true)
	for p in adj.keys():
		for q in adj[p]:
			adj[q].append(p)
	var visited := {start: true}
	var stack: Array = [start]
	while not stack.is_empty():
		var u: Vector2i = stack.pop_back()
		for v in adj.get(u, []):
			if not visited.has(v):
				visited[v] = true
				stack.append(v)
	return visited

## 完整可达矩阵 R（|V| × |V| 布尔）—— **只用于小地图的单元测试**（O(n^3)）。
func reach_matrix(kernel, forward_only: bool = true) -> Dictionary:
	var ns := nodes()
	var idxmap := {}
	for i in range(ns.size()):
		idxmap[ns[i]] = i
	var n := ns.size()
	var flat := PackedByteArray()
	flat.resize(n * n)
	var adj := adjacency(kernel, forward_only, true)
	for p in adj.keys():
		var i: int = idxmap[p]
		for q in adj[p]:
			flat[i * n + idxmap[q]] = 1
	var r := bool_closure(flat, n)
	return {"nodes": ns, "index": idxmap, "R": r, "n": n}

## Warshall 布尔闭包（原地返回新数组）：R = I ∨ A ∨ A² ∨ ...
static func bool_closure(flat: PackedByteArray, n: int) -> PackedByteArray:
	var r := flat.duplicate()
	for i in range(n):
		r[i * n + i] = 1
	for k in range(n):
		for i in range(n):
			if r[i * n + k] == 1:
				var base_i := i * n
				var base_k := k * n
				for j in range(n):
					if r[base_k + j] == 1:
						r[base_i + j] = 1
	return r

# --------------------------------------------------------------------------
# 变换（全部是矩阵操作）
# --------------------------------------------------------------------------

## 把最左/最右一列变成实心 —— 地图边界墙。没有它会出现「掉到地图底再横穿」的假通路。
func wall_edges() -> RefCounted:
	var nb := blocked.duplicate()
	for y in range(h):
		if w > 0:
			nb[y * w + 0] = 1
			nb[y * w + w - 1] = 1
	var v = load("res://gen/voxel_map.gd").new(cells.duplicate(), nb, spawn, goal)
	return v

## 开门/开捷径 = 把若干格点的 blocked 置 0。**单调操作**（只加边不删边）。
func open_cells(list: Array) -> RefCounted:
	var nb := blocked.duplicate()
	var nc := cells.duplicate()
	for c in list:
		var x: int = c.x
		var y: int = c.y
		if x < 0 or x >= w or y < 0 or y >= h:
			continue
		nb[y * w + x] = 0
		if nc[y][x] == DOOR:
			var row: String = nc[y]
			nc[y] = row.substr(0, x) + DOOR_OPEN + row.substr(x + 1)
	var v = load("res://gen/voxel_map.gd").new(nc, nb, spawn, goal)
	return v

func close_cells(list: Array) -> RefCounted:
	var nb := blocked.duplicate()
	var nc := cells.duplicate()
	for c in list:
		var x: int = c.x
		var y: int = c.y
		if x < 0 or x >= w or y < 0 or y >= h:
			continue
		nb[y * w + x] = 1
		if nc[y][x] == DOOR_OPEN:
			var row: String = nc[y]
			nc[y] = row.substr(0, x) + DOOR + row.substr(x + 1)
	var v = load("res://gen/voxel_map.gd").new(nc, nb, spawn, goal)
	return v

func clone() -> RefCounted:
	var v = load("res://gen/voxel_map.gd").new(cells.duplicate(), blocked.duplicate(), spawn, goal)
	return v

## 把地形改写成「只有走廊表面 + 天空」的稀疏占用图 —— 走廊连通性验证专用。
##
## 直接对真实矩阵跑 BFS 会得到平级的假通路（缺口列一直空到底，角色能掉到底行
## 再横穿过去）。这张改写图把「只有走廊地面可以走」这个假设显式化。
##
## ground_at[x] = 该列走廊**地面**那一行（站立格在它上面一格）。
## 占用规则：y >= ground_at[x] -> 实心（地面 + 大地）；否则看原图。
## 地面只保留一格而不是填到底：否则角色站在格子边缘、身体半宽越过邻列时
## 就会撞上「脚下的地」，连地面前进一格都判成穿墙。
func walk_cells(ground_at: Array, void_cols: Dictionary = {}) -> RefCounted:
	var nc := PackedStringArray()
	var nb := PackedByteArray()
	nb.resize(w * h)
	for y in range(h):
		var chars := PackedByteArray()
		chars.resize(w)
		for x in range(w):
			var solid := false
			if void_cols.has(x):
				solid = true                     # 缺口列：走廊图里整列当实心
			elif y >= int(ground_at[x]):
				solid = true
			else:
				solid = BLOCKING.contains(cells[y][x])
			nb[y * w + x] = 1 if solid else 0
			chars[x] = SOLID.unicode_at(0) if solid else EMPTY.unicode_at(0)
		nc.append(chars.get_string_from_ascii())
	var sp := Vector2i(-1, -1)
	var gl := Vector2i(-1, -1)
	if spawn.x >= 0 and standable(spawn.x, spawn.y):
		sp = spawn
	if goal.x >= 0 and standable(goal.x, goal.y):
		gl = goal
	var v = load("res://gen/voxel_map.gd").new(nc, nb, sp, gl)
	return v

# --------------------------------------------------------------------------
# 指纹与显示
# --------------------------------------------------------------------------

func fingerprint() -> String:
	var buf := PackedByteArray()
	for y in range(h):
		buf.append_array(cells[y].to_utf8_buffer())
	buf.append_array(blocked)
	return Dig.sha256_bytes(buf).slice(0, 8).hex_encode()

func render(marks: Dictionary = {}) -> String:
	var out := PackedStringArray()
	for y in range(h):
		var row := ""
		for x in range(w):
			var p := Vector2i(x, y)
			if marks.has(p):
				row += str(marks[p])
			elif blocked[y * w + x] == 1 and cells[y][x] == EMPTY:
				row += SOLID
			else:
				row += cells[y][x]
		out.append(row)
	return "\n".join(out)
