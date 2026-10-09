# 断言工具 —— 极简但足够：每组断言有 ID、有证据串、有通过/失败计数。
extends RefCounted

var passed: int = 0
var failed: int = 0
var results: Array = []       # [{id, ok, msg}]
var _t0: int = 0

func begin(title: String) -> void:
	_t0 = Time.get_ticks_msec()
	print("\n=== %s ===" % title)

func ok(cid: String, cond: bool, msg: String = "") -> bool:
	if cond:
		passed += 1
		results.append({"id": cid, "ok": true, "msg": msg})
		return true
	failed += 1
	results.append({"id": cid, "ok": false, "msg": msg})
	print("  ✗ [%s] %s" % [cid, msg])
	return false

func eq_int(cid: String, got: int, want: int, msg: String = "") -> bool:
	return ok(cid, got == want, "%s got=%d want=%d" % [msg, got, want])

func near(cid: String, got: float, want: float, tol: float, msg: String = "") -> bool:
	return ok(cid, absf(got - want) <= tol, "%s got=%.4f want=%.4f tol=%.4f" % [msg, got, want, tol])

func info(msg: String) -> void:
	print("  · %s" % msg)

func summary(title: String) -> int:
	var dt := Time.get_ticks_msec() - _t0
	print("\n--- %s: 通过 %d / 失败 %d（%.0f ms）---" % [title, passed, failed, float(dt)])
	if failed > 0:
		print("失败明细：")
		for r in results:
			if not r["ok"]:
				print("  ✗ [%s] %s" % [r["id"], r["msg"]])
	return failed
