/// 书源级变量 / 登录信息存储（进程级单例）。
///
/// 对应 legado 里 JS 侧的 `source` 对象：
///   `source.getVariable()` / `setVariable(v)` / `putVariable(v)`、
///   `source.getLoginInfo()` / `putLoginInfo(v)` / `getLoginInfoMap()`、
///   `source.putLoginHeader(v)` / `getLoginHeader()` / `removeLoginHeader()` /
///   `removeLoginInfo()`。
///
/// ── 为什么必须是**进程级**，不能挂在 `AnalyzeRule` 实例上 ──────────
/// 搜索 / 详情 / 目录 / 正文**各自 new 一个 `AnalyzeRule`**
///（全仓 12 处构造点），若变量存在实例里 ⇒ 在 `searchUrl` 求值阶段
/// `source.setVariable(...)` 存下的值，到 `bookInfo` 阶段**已经丢了**
/// ⇒ `source.getVariable()` 永远为空 ⇒ 依赖该机制的源整条链路失效。
///
/// ── 分组键 ───────────────────────────────────────────────────
/// 按**书源身份**分组（`bookSourceUrl`；缺失时退回 `baseUrl`）——
/// 同一书源跨步骤共享 ✓，不同书源互不串 ✓，与 legado「书源级变量」语义一致。
///
/// ⚠️ 目前为**进程内内存**存储（与 `SourceCookieStore` 同策略，不落盘）：
///    重启 App 后 `source.*` 变量重置。legado 会把 variable 持久化进书源，
///    如需跨会话保留，可在此接入 SharedPreferences。
library;

/// 书源级变量 / 登录信息存储（进程级单例）。
class SourceVariableStore {
  SourceVariableStore._();
  static final SourceVariableStore instance = SourceVariableStore._();

  /// 书源身份 → { 变量名: 值 }
  final Map<String, Map<String, String>> _bySource =
      <String, Map<String, String>>{};

  /// 取某书源的变量箱（不存在则创建）。
  Map<String, String> box(String sourceKey) =>
      _bySource.putIfAbsent(sourceKey, () => <String, String>{});

  /// 读取（无则空串）。
  String get(String sourceKey, String name) =>
      _bySource[sourceKey]?[name] ?? '';

  /// 写入。
  void put(String sourceKey, String name, String value) {
    box(sourceKey)[name] = value;
  }

  /// 删除单个键。
  void remove(String sourceKey, String name) {
    _bySource[sourceKey]?.remove(name);
  }

  /// 清空某书源的全部变量（诊断 / 换源用）。
  void clearSource(String sourceKey) => _bySource.remove(sourceKey);

  /// 全部清空（测试用）。
  void clear() => _bySource.clear();
}
