# Projectile —— 投射物（箭矢 / 法术弹 / 爆炸）
#
# 单独一个文件而不是 actor.gd 的内部类：内部类 extend 外层脚本会形成循环引用，
# GDScript 直接拒绝编译。踩过一次，记在这里。

extends "res://actors/actor.gd"


var owner_actor = null
var dmg: int = 5
var life: int = 200
var gravity: float = 0.0
var radius: float = 4.0
var homing: float = 0.0
var kb: Dictionary = {"x": 2.0, "y": -1.0}
var pierce: bool = false
var color: int = 0

func _init() -> void:
	kind = "projectile"
	hw = 4.0
	h = 8.0
	hp = 1
	max_hp = 1

func step() -> void:
	if not alive:
		return
	life -= 1
	if life <= 0:
		alive = false
		return
	if homing > 0.0 and owner_actor != null and owner_actor.alive:
		var target = level.player
		if target != null and target.alive:
			var want: Vector2 = (target.center() - center()).normalized() * vel.length()
			vel = vel.lerp(want, homing)
	if gravity != 0.0:
		vel.y += gravity / float(Cfg.FPS)
	var np: Vector2 = p + vel / float(Cfg.FPS)
	var cx := int(floor(np.x / TILE))
	var cy := int(floor((np.y - h * 0.5) / TILE))
	if level.is_blocked_tile(cx, cy):
		alive = false
		level.log_event("proj_wall", {"who": id})
		return
	p = np
	var hb := Rect2(p.x - radius, p.y - h * 0.5, radius * 2.0, h)
	for a in level.actors:
		if a == owner_actor or not a.alive or a.kind == "projectile":
			continue
		# 友军不伤害友军
		if owner_actor != null and a.kind == owner_actor.kind:
			continue
		if hb.intersects(a.hurt_box()):
			a.take_hit(self, dmg, kb, 8.0, 2, false)
			if not pierce:
				alive = false
			return
