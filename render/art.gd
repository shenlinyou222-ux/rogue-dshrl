# ArtProvider —— 占位美术（**可替换的接缝就在这里**）
#
# 目标：不依赖任何外部素材就能跑起来，同时让「换成真美术」只需要改这一个文件。
#
# 接缝长什么样：
#   所有可见物都通过 `draw_*` 系列函数画出来，函数签名的输入是**语义**
#   （actor 原型 / 状态 / 帧 / 朝向），不是像素坐标。要换成贴图：
#     1. 载入纹理；
#     2. 在 `sprite_for(kind, state, frame)` 里返回对应的 AtlasTexture；
#     3. `draw_actor()` 里把 `draw_rect` 换成 `draw_texture_rect`。
#   其它代码（生成、战斗、AI）**一行都不用改**。
#
# 为什么占位用「矩形 + 颜色」而不是随机噪点：
#   读屏能力是调试的第一生产力。颜色区分原型、亮度区分状态、闪白表示受击，
#   这样无头截图也能一眼看出「谁在打谁、谁在预警」。

extends RefCounted

const Cfg = preload("res://core/constants.gd")

const TILE := 16

# 主题配色：同一份几何换主题就是另一张图（§8.4 主题由 narrative θ 驱动）
const THEMES := {
	"crypt":   {"bg": Color(0.08, 0.07, 0.10), "solid": Color(0.30, 0.28, 0.34), "edge": Color(0.42, 0.40, 0.48), "accent": Color(0.55, 0.85, 0.60)},
	"ice":     {"bg": Color(0.06, 0.09, 0.13), "solid": Color(0.26, 0.34, 0.44), "edge": Color(0.52, 0.72, 0.86), "accent": Color(0.60, 0.85, 1.00)},
	"ember":   {"bg": Color(0.11, 0.06, 0.05), "solid": Color(0.34, 0.22, 0.18), "edge": Color(0.62, 0.36, 0.22), "accent": Color(1.00, 0.66, 0.30)},
	"verdant": {"bg": Color(0.05, 0.09, 0.06), "solid": Color(0.20, 0.30, 0.20), "edge": Color(0.36, 0.52, 0.32), "accent": Color(0.70, 0.92, 0.45)},
	"void":    {"bg": Color(0.05, 0.04, 0.09), "solid": Color(0.20, 0.16, 0.30), "edge": Color(0.46, 0.34, 0.70), "accent": Color(0.78, 0.62, 1.00)},
}

## 每类敌人的形状语义（换成真美术时这张表就是「哪个原型用哪张贴图」的对照表）
const ENEMY_SHAPE := {
	"rusher":   {"body": Vector2(14, 22), "head": 4.0, "color": Color(0.86, 0.35, 0.32), "spike": true},
	"shielded": {"body": Vector2(18, 24), "head": 4.0, "color": Color(0.42, 0.55, 0.86), "shield": true},
	"archer":   {"body": Vector2(13, 22), "head": 4.0, "color": Color(0.62, 0.80, 0.42), "bow": true},
	"caster":   {"body": Vector2(13, 22), "head": 5.0, "color": Color(0.72, 0.46, 0.88), "orb": true},
	"exploder": {"body": Vector2(15, 18), "head": 6.0, "color": Color(0.92, 0.66, 0.24), "fuse": true},
	"flyer":    {"body": Vector2(16, 16), "head": 3.0, "color": Color(0.55, 0.86, 0.90), "wings": true},
	"brute":    {"body": Vector2(22, 30), "head": 6.0, "color": Color(0.78, 0.30, 0.24), "horns": true},
	"summoner": {"body": Vector2(15, 24), "head": 5.0, "color": Color(0.40, 0.80, 0.70), "staff": true},
	"boss":     {"body": Vector2(30, 40), "head": 8.0, "color": Color(0.90, 0.20, 0.35), "horns": true},
}

static func theme(name: String) -> Dictionary:
	return THEMES.get(name, THEMES["crypt"])

static func rarity_color(r: int) -> Color:
	match r:
		0:
			return Color(0.78, 0.78, 0.80)
		1:
			return Color(0.40, 0.72, 1.00)
		2:
			return Color(0.72, 0.45, 1.00)
		_:
			return Color(1.00, 0.72, 0.25)

# --------------------------------------------------------------------------
# 世界绘制
# --------------------------------------------------------------------------

## 只画摄像机可见的格子（750 列的地图不能整张画）
static func draw_map(ci: CanvasItem, level, cam: Rect2, theme_name: String) -> void:
	var th := theme(theme_name)
	var x0: int = maxi(0, int(cam.position.x / TILE) - 1)
	var x1: int = mini(level.map.w - 1, int((cam.position.x + cam.size.x) / TILE) + 1)
	var y0: int = maxi(0, int(cam.position.y / TILE) - 1)
	var y1: int = mini(level.map.h - 1, int((cam.position.y + cam.size.y) / TILE) + 1)
	var solid := th["solid"] as Color
	var edge := th["edge"] as Color
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var c := Vector2(x * TILE, y * TILE)
			if level.map.is_blocked(x, y):
				var opened: bool = level.open_cells.has(x * 100000 + y)
				if opened:
					# 已开的门：画成「半开的门框」而不是消失（玩家要知道这里曾经是门）
					ci.draw_rect(Rect2(c, Vector2(TILE, TILE)), Color(edge.r, edge.g, edge.b, 0.28), false, 1.0)
					continue
				var top_open: bool = not level.map.is_blocked(x, y - 1)
				ci.draw_rect(Rect2(c, Vector2(TILE, TILE)), solid)
				if top_open:
					# 地表高光：这是「哪块能站」的唯一视觉线索，必须有
					ci.draw_rect(Rect2(c, Vector2(TILE, 3)), edge)
			else:
				var t: String = level.map.at(x, y)
				if t == "B":
					ci.draw_circle(Vector2(x * TILE + 8, y * TILE + 8), 4.0, Color(0.95, 0.85, 0.35))
				elif t == "K":
					ci.draw_rect(Rect2(x * TILE + 4, y * TILE + 4, 8, 8), Color(1.0, 0.85, 0.30))
				elif t == "^":
					# 尖刺：三角
					var px := float(x * TILE)
					var py := float(y * TILE)
					for k in range(2):
						var bx := px + float(k) * 8.0
						ci.draw_colored_polygon(PackedVector2Array([
							Vector2(bx, py + 16.0), Vector2(bx + 4.0, py + 4.0),
							Vector2(bx + 8.0, py + 16.0)]), Color(0.85, 0.35, 0.40))

static func draw_actors(ci: CanvasItem, level, cam: Rect2) -> void:
	for a in level.actors:
		if a.kind == "projectile":
			var col := Color(1.0, 0.85, 0.4)
			ci.draw_circle(a.center(), a.radius + 1.0, col)
			continue
		if not a.alive:
			continue
		var pos: Vector2 = a.p
		if pos.x < cam.position.x - 64.0 or pos.x > cam.position.x + cam.size.x + 64.0:
			continue
		if a.kind == "player":
			draw_player(ci, a)
		else:
			draw_enemy(ci, a)

static func draw_player(ci: CanvasItem, pl) -> void:
	var base := Color(0.90, 0.92, 0.96)
	if pl.invuln > 0 and (pl.invuln % 6) < 3:
		base = Color(1.0, 1.0, 1.0, 0.55)
	if pl.flash > 0:
		base = Color(1.0, 0.6, 0.6)
	var body := Rect2(pl.p.x - 6.0, pl.p.y - 28.0, 12.0, 28.0)
	ci.draw_rect(body, base)
	# 头
	ci.draw_circle(Vector2(pl.p.x, pl.p.y - 32.0), 5.0, base.darkened(0.1))
	# 武器：按状态画不同姿态（这就是「动作」在没有美术时的可读表达）
	var sx: float = float(pl.facing)
	var st: String = pl.state
	var wcol := Color(0.85, 0.85, 0.9)
	if st.begins_with("attack") or st == "air_attack" or st == "parry_counter":
		var prog: float = clampf(float(pl.state_frame) / 10.0, 0.0, 1.2)
		var ang: float = lerpf(-1.1, 0.9, prog)
		var tip := Vector2(pl.p.x + sx * (10.0 + 18.0 * cos(ang)), pl.p.y - 20.0 - 10.0 * sin(ang))
		ci.draw_line(Vector2(pl.p.x, pl.p.y - 18.0), tip, wcol, 3.0)
	elif st == "block":
		ci.draw_rect(Rect2(pl.p.x + sx * 7.0 - 3.0, pl.p.y - 30.0, 6.0, 22.0), Color(0.6, 0.8, 1.0))
	elif st == "parry":
		ci.draw_arc(Vector2(pl.p.x + sx * 6.0, pl.p.y - 18.0), 14.0, -1.2, 1.2, 12, Color(1.0, 0.95, 0.6), 2.0)
	elif st == "roll":
		ci.draw_circle(Vector2(pl.p.x, pl.p.y - 12.0), 10.0, Color(0.95, 0.95, 1.0, 0.8))
	else:
		ci.draw_line(Vector2(pl.p.x, pl.p.y - 18.0), Vector2(pl.p.x + sx * 14.0, pl.p.y - 10.0), wcol, 3.0)
	# 蓄力/治疗提示
	if st == "heal":
		ci.draw_circle(Vector2(pl.p.x, pl.p.y - 34.0), 6.0 + float(pl.state_frame % 12) * 0.4,
			Color(0.5, 1.0, 0.6, 0.5))

static func draw_enemy(ci: CanvasItem, e) -> void:
	var sh: Dictionary = ENEMY_SHAPE.get(e.archetype, ENEMY_SHAPE["rusher"])
	var col: Color = sh["color"]
	var sz: Vector2 = sh["body"]
	if e.flash > 0:
		col = Color(1, 1, 1)
	elif e.elite:
		col = col.lightened(0.18)
	var r := Rect2(e.p.x - sz.x * 0.5, e.p.y - sz.y, sz.x, sz.y)
	# 预警：整块闪烁 + 一层外扩的光（这是公平性的视觉契约）
	if e.state == "telegraph":
		var tel: int = int(e.data.get("telegraph", 16))
		var t: float = 1.0 - clampf(float(e.state_frame) / float(maxi(1, tel)), 0.0, 1.0)
		var flash: bool = (e.state_frame % 8) < 4
		col = Color(1.0, 0.45, 0.35) if flash else col
		ci.draw_rect(r.grow(3.0 + 4.0 * t), Color(1.0, 0.4, 0.3, 0.35 * t), false, 2.0)
	ci.draw_rect(r, col)
	ci.draw_circle(Vector2(e.p.x, e.p.y - sz.y - 3.0), float(sh.get("head", 4.0)), col.darkened(0.15))
	if bool(sh.get("shield", false)) and e.guard_active:
		ci.draw_rect(Rect2(e.p.x + float(e.facing) * (sz.x * 0.5) - 2.0, e.p.y - sz.y, 4.0, sz.y), Color(0.7, 0.8, 1.0))
	if bool(sh.get("horns", false)):
		var hx: float = e.p.x
		ci.draw_line(Vector2(hx - 6.0, e.p.y - sz.y - 4.0), Vector2(hx - 10.0, e.p.y - sz.y - 12.0), col, 2.0)
		ci.draw_line(Vector2(hx + 6.0, e.p.y - sz.y - 4.0), Vector2(hx + 10.0, e.p.y - sz.y - 12.0), col, 2.0)
	if bool(sh.get("wings", false)):
		var flap: float = sin(float(Time.get_ticks_msec()) * 0.02) * 3.0
		ci.draw_line(Vector2(e.p.x - 6.0, e.p.y - sz.y * 0.6), Vector2(e.p.x - 16.0, e.p.y - sz.y * 0.6 - flap), col, 2.0)
		ci.draw_line(Vector2(e.p.x + 6.0, e.p.y - sz.y * 0.6), Vector2(e.p.x + 16.0, e.p.y - sz.y * 0.6 - flap), col, 2.0)
	if bool(sh.get("staff", false)) or bool(sh.get("orb", false)):
		ci.draw_circle(Vector2(e.p.x + float(e.facing) * 10.0, e.p.y - sz.y * 0.7), 4.0, Color(0.7, 1.0, 0.9, 0.8))
	# 血条（精英/Boss 才有，普通怪用「受击闪白」表达血量）
	if e.elite or e.archetype == "boss":
		var w: float = sz.x + 6.0
		var ratio: float = float(e.hp) / float(maxi(1, e.max_hp))
		ci.draw_rect(Rect2(e.p.x - w * 0.5, e.p.y - sz.y - 14.0, w, 3.0), Color(0, 0, 0, 0.6))
		ci.draw_rect(Rect2(e.p.x - w * 0.5, e.p.y - sz.y - 14.0, w * ratio, 3.0), Color(0.9, 0.3, 0.3))

static func draw_pickups(ci: CanvasItem, level) -> void:
	for pk in level.pickups:
		if pk.taken:
			continue
		var c := Vector2(float(pk.cell.x) * TILE + 8.0, float(pk.cell.y) * TILE + 8.0)
		var bob: float = sin(float(pk.bob) * 0.08) * 2.0
		var col: Color = rarity_color(int(pk.item.get("rarity", 0)))
		if pk.kind == "chest":
			ci.draw_rect(Rect2(c.x - 7.0, c.y - 8.0 + bob, 14.0, 12.0), Color(0.55, 0.40, 0.22))
			ci.draw_rect(Rect2(c.x - 7.0, c.y - 8.0 + bob, 14.0, 3.0), col)
		else:
			ci.draw_rect(Rect2(c.x - 4.0, c.y - 4.0 + bob, 8.0, 8.0), col)
			ci.draw_rect(Rect2(c.x - 4.0, c.y - 4.0 + bob, 8.0, 8.0), Color(1, 1, 1, 0.7), false, 1.0)

static func draw_decor(ci: CanvasItem, level, cam: Rect2, theme_name: String) -> void:
	var th := theme(theme_name)
	for d in level.decor_cfg:
		var c := Vector2(float(d.cell.x) * TILE + 8.0, float(d.cell.y) * TILE + 8.0)
		if c.x < cam.position.x - 32.0 or c.x > cam.position.x + cam.size.x + 32.0:
			continue
		match str(d.kind):
			"torch":
				ci.draw_rect(Rect2(c.x - 1.0, c.y - 2.0, 3.0, 12.0), Color(0.4, 0.3, 0.2))
				ci.draw_circle(Vector2(c.x, c.y - 4.0), 5.0, Color(1.0, 0.7, 0.25, 0.55))
			"banner":
				ci.draw_rect(Rect2(c.x - 5.0, c.y - 20.0, 10.0, 18.0), th["accent"] * Color(1, 1, 1, 0.5))
			"rubble":
				ci.draw_rect(Rect2(c.x - 6.0, c.y + 4.0, 5.0, 4.0), th["solid"].lightened(0.1))
				ci.draw_rect(Rect2(c.x + 1.0, c.y + 6.0, 4.0, 3.0), th["solid"].lightened(0.05))
			"chain":
				ci.draw_line(Vector2(c.x, c.y - 24.0), Vector2(c.x, c.y + 6.0), Color(0.45, 0.45, 0.5), 1.0)
			"moss":
				ci.draw_rect(Rect2(c.x - 4.0, c.y + 5.0, 8.0, 2.0), Color(0.3, 0.5, 0.3, 0.6))
