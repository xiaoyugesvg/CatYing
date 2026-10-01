// ============================================================
// 宽容的数值转换（阅读模块内共用）
// ============================================================
//
// ── 为什么需要这个（踩过的坑）─────────────────────────────────
// 从网络/配置里读到的 JSON，**字段类型是不受控的**：
//   · 引擎可能把数字转成字符串（如地图 API 的 id 常是字符串）
//   · 手写的源配置里 `"use_frame": "1"` 和 `1` 都有人写
//   · 同一字段在 A 站是 int、B 站是 double
//
// 而 Dart 的 `x as num` / `x as int` 在类型不符时**直接抛异常**：
//     type 'String' is not a subtype of type 'num' in type cast
// 症状极难定位 —— 整个页面只显示这行英文，看不出是哪个字段、
// 也不知道是哪本书触发的。
//
// 用这些函数把"某字段类型不对"**降级成"该字段取默认值"**：
// 一个源配置写错了不应该让整个漫画页白屏。
//
// 注意：`lib/music` 下有一份等价的实现（models.dart 里）。
// 两个模块刻意**不互相依赖**（阅读/音乐是独立体系），
// 所以各留一份而不是跨模块 import。

/// 任意值 → int。字符串数字也能转；转不了返回 0。
int asInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is num) return v.toInt();
  if (v is bool) return v ? 1 : 0;
  return int.tryParse(v.toString().trim()) ?? 0;
}

/// 任意值 → double。字符串数字也能转；转不了返回 0。
double asDouble(dynamic v) {
  if (v == null) return 0;
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().trim()) ?? 0;
}

/// 可空 int —— 区分"没有这个值"和"值是 0"。
///
/// 两者语义不同：`评分 0` 和 `没有评分` 在 UI 上不该长一样。
int? asIntOrNull(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  return int.tryParse(s);
}

/// 可空 double
double? asDoubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is num) return v.toDouble();
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  return double.tryParse(s);
}

/// 任意值 → 非空 String（null 变空串，省掉 UI 层到处判空）
String asStr(dynamic v) => v?.toString() ?? '';

/// 任意值 → bool。
///
/// 兼容常见写法：`true` / `"true"` / `1` / `"1"` / `"yes"`。
/// 配置里用字符串写布尔值很常见（JSON5/手写配置尤其多）。
bool asBool(dynamic v, {bool fallback = false}) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  switch (v.toString().trim().toLowerCase()) {
    case 'true':
    case '1':
    case 'yes':
    case 'on':
      return true;
    case 'false':
    case '0':
    case 'no':
    case 'off':
      return false;
  }
  return fallback;
}
