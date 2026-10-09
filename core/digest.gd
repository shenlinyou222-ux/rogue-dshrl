# Digest —— SHA-256 摘要与稳定哈希工具
#
# 用途：世界线编号、spec 指纹、每头独立随机流的密钥派生。
# 全部是纯函数，无状态。

extends RefCounted

## 字节串 -> SHA-256（32 字节）
static func sha256_bytes(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()

## 字符串（UTF-8）-> SHA-256 十六进制
static func sha256_hex(s: String) -> String:
	return sha256_bytes(s.to_utf8_buffer()).hex_encode()

## 字符串 -> 前 8 字节小端解释为正整数（用于 RNG 密钥派生）
## 只用低 63 位，避免符号位带来的移位歧义。
static func h63(s: String) -> int:
	var d := sha256_bytes(s.to_utf8_buffer())
	var v := 0
	for i in range(8):
		v |= int(d[i]) << (8 * i)
	return v & 0x7FFFFFFFFFFFFFFF

## 字符串 -> 前 4 字节小端（32 位无符号，用 int 承载）
static func h32(s: String) -> int:
	var d := sha256_bytes(s.to_utf8_buffer())
	return int(d[0]) | (int(d[1]) << 8) | (int(d[2]) << 16) | (int(d[3]) << 24)

## 16 进制指纹：前 n 个字节（默认 8 = 16 个 hex 字符，与文档一致）
static func fingerprint(s: String, n: int = 8) -> String:
	var d := sha256_bytes(s.to_utf8_buffer())
	return d.slice(0, n).hex_encode()

## 稳定的 32 位混合（splitmix32 终混），用于把任意整数打散。
static func mix32(x: int) -> int:
	var z: int = x & 0xFFFFFFFF
	z = ((z ^ (z >> 16)) * 0x21F0AAAD) & 0xFFFFFFFF
	z = ((z ^ (z >> 15)) * 0x735A2D97) & 0xFFFFFFFF
	return (z ^ (z >> 15)) & 0xFFFFFFFF
