/// **书源/节点失败文案的统一出口** ✓（"同一原因 → 同一句话" ✓）。
///
/// ── 为什么需要它（今天核实到的现状 ✗）───────────────────────────
/// 失败文案此前**散落在各页面各写一遍** ✗（80+ 处命中 ✓）：
///   · `book_source_search_page:185-205` —— 500/404/403/超时/其它码 ✓（映射得**最好的一处** ✓）
///   · `book_source_health_page:79-84`   —— 网络不通 / 解析失败 ✓
///   · `zlibrary_service` / `source_repo_page` / `book_download_service` / `tts_engine_page` … ✗
/// 后果 ✗：**同一个原因**在体检页叫「网络不通」✓、在搜索页叫「该源拒绝了访问（HTTP 403）」✓、
/// 在别处又叫「数据解析失败」✗ → 用户看到的现象就是"**同样的错误，说法不一样**" ✗✗。
/// `book_source_health_page:84` 的注释里作者也写着「**两处必须同步**」✗ —— 说明这重复很脆 ✓。
///
/// ── 设计取舍 ──────────────────────────────────────────────────
///   · **纯函数** ✓：只吃 `Object error` ✓，不 import 任何 service ✓
///     （页面 / 服务 / 体检都能复用 ✓，也不会形成依赖环 ✓）。
///   · **分级固定为四类** ✓（与体检页统计口径一致 ✓）：网络不通 / 需要登录或请求头 /
///     源站接口失效 / 规则解析失败 ✓。
///   · **文案里必须给"下一步动作"** ✓（请换源 ✓ 请稍后重试 ✓ 请更新书源 ✓）——
///     正是用户要的"**能看失败原因**" ✓（与今天的日志桥接互补 ✓✓）。
///   · ⚠️ **文案是纯文本，不带任何 Markdown 标记** ✗✓ —— 它的落点是 `Text()` / `SnackBar` ✓，
///     写 `**加粗**` 会**原样显示星号** ✗（这是我第一版的错 ✗，已改 ✓）。
///   · **不吞原始信息** ✗：`detail` 保留 HTTP 码 / 原文 ✓，便于日志对照 ✓。
library;

/// 失败大类 ✓（与 `book_source_health_page` 的统计口径一致 ✓）
enum SourceFailKind {
  /// 网络不通（超时/拒连/DNS/连接失败 ✓）
  network,

  /// 服务器有响应但拒绝（403/需要登录/Cookie 失效 ✓）
  denied,

  /// 源站接口失效或结构变了（404/5xx/接口返回非预期 ✓）
  apiBroken,

  /// 拿到了数据但规则解析不出来（选择器失效/返回 0 条 ✓）
  parseFail,

  /// 无法归类
  unknown,
}

/// 统一结果 ✓：`kind` 供统计与分支 ✓，`text` 是**给用户看的那一句话** ✓。
class SourceFailInfo {
  const SourceFailInfo(this.kind, this.text, {this.detail = ''});
  final SourceFailKind kind;
  final String text;
  final String detail;
}

/// 从**任意异常/错误字符串**推断失败类别与统一文案 ✓。
///
/// 判据顺序**有意如此** ✗✓：先"拒绝"✓、再"接口失效"✗、再"网络"✗、最后"解析"✓ ——
/// 因为 403 的报错里往往同时含 "connection" 之类字样 ✓，若先判网络就会**误诊** ✗
/// （`book_source_health_page:79-82` 记的正是这个坑 ✓：223 个源曾被全判成"解析失败" ✗✗）。
SourceFailInfo describeSourceFail(Object? error, {String what = '该源'}) {
  final raw = (error ?? '').toString();
  final low = raw.toLowerCase();

  // ① 明确拒绝 ✓（服务器有响应，但状态码/登录态不对 ✓）
  final code = _firstHttpCode(raw);
  if (low.contains('status code of 403') ||
      code == 403 ||
      low.contains('forbidden')) {
    return SourceFailInfo(
      SourceFailKind.denied,
      '$what拒绝了访问（HTTP 403）：可能需要登录或补请求头，请换源',
      detail: raw,
    );
  }
  if (code == 401 || low.contains('unauthorized') || raw.contains('登录已失效')) {
    return SourceFailInfo(
      SourceFailKind.denied,
      '$what要求先登录（HTTP 401）：登录已失效或未登录，请重新登录后重试',
      detail: raw,
    );
  }

  // ② 接口失效 ✓（404 主机不对 / 5xx 源站挂了 / 分类接口报错 ✓）
  if (code == 404) {
    return SourceFailInfo(
      SourceFailKind.apiBroken,
      '$what地址已失效（HTTP 404）：该源可能换域名了，请更新书源',
      detail: raw,
    );
  }
  if (code != null && code >= 500) {
    return SourceFailInfo(
      SourceFailKind.apiBroken,
      '$what服务器出错（HTTP $code）：源站暂时不可用，请稍后重试或换源',
      detail: raw,
    );
  }
  if (raw.contains('接口失效') || raw.contains('分类接口返回')) {
    return SourceFailInfo(
      SourceFailKind.apiBroken,
      '$what的接口已失效：请换源或更新书源',
      detail: raw,
    );
  }

  // ③ 网络不通 ✓（超时 / 拒连 / DNS / 连接失败 ✓）
  if (low.contains('timeout') ||
      low.contains('timed out') ||
      raw.contains('超时') ||
      low.contains('connection') ||
      low.contains('dioexception') ||
      low.contains('socketexception') ||
      low.contains('failed host lookup') ||
      raw.contains('拒绝连接')) {
    return SourceFailInfo(
      SourceFailKind.network,
      '连接$what超时或网络不通：请检查网络/代理后重试，或换源',
      detail: raw,
    );
  }

  // ④ 解析不出来 ✓（拿到了页面但规则对不上 ✓）
  if (low.contains('parse') ||
      raw.contains('解析') ||
      raw.contains('规则') ||
      raw.contains('返回 0 条') ||
      raw.contains('为空')) {
    return SourceFailInfo(
      SourceFailKind.parseFail,
      '$what返回的内容解析不出来（规则可能已过期）：请更新书源，或换源',
      detail: raw,
    );
  }

  // ⑤ 兜底 ✓：**不谎报分类** ✗，把原文附上让用户/日志能自查 ✓
  return SourceFailInfo(
    SourceFailKind.unknown,
    '$what失败：${raw.isEmpty ? '未知原因' : _short(raw)}',
    detail: raw,
  );
}

/// HTTP 状态码 ✓（从常见错误字符串里抽取 ✓；抽不到返回 null ✗）
int? _firstHttpCode(String raw) {
  final m = RegExp(r'(?:status code of|statusCode:?|HTTP)\s*(\d{3})',
          caseSensitive: false)
      .firstMatch(raw);
  if (m != null) return int.tryParse(m.group(1)!);
  final m2 = RegExp(r'\b([45]\d{2})\b').firstMatch(raw);
  return m2 == null ? null : int.tryParse(m2.group(1)!);
}

String _short(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= 80 ? one : '${one.substring(0, 80)}…';
}
