import '../models/app_config.dart';
import 'app_log.dart';

/// 一条正则替换规则（`pattern#replacement` 形态）。
class _Replacement {
  final RegExp pattern;
  final String replacement;

  const _Replacement(this.pattern, this.replacement);
}

/// 一组带域名作用域的规则。
/// [hosts] 为空表示全局规则；非空时仅当播放地址 host 命中（同域或子域）才生效。
class _RuleGroup {
  final List<String> hosts;
  final List<RegExp> blockRegexes = [];
  final List<_Replacement> rewrites = [];

  _RuleGroup({required this.hosts});

  bool get isEmpty => blockRegexes.isEmpty && rewrites.isEmpty;
}

/// 视频播放广告过滤 - 单例。
///
/// 数据来自配置里的 `ads`（字符串数组）与 `rules`（[RuleConfig] 列表）。
/// 全部解析都容错：任何一条规则编译失败都静默跳过，绝不抛异常。
/// 无规则时 [enabled] 为 false，调用方应保持原有行为不变。
class AdFilterService {
  AdFilterService._internal();
  static final AdFilterService instance = AdFilterService._internal();

  final List<String> _blockedHosts = [];
  final List<_RuleGroup> _groups = [];

  /// 是否存在任何可用规则。无规则返回 false。
  bool get enabled => _blockedHosts.isNotEmpty || _groups.isNotEmpty;

  /// 用最新配置重建规则集。传 null / 空列表即清空（等价于关闭过滤）。
  void load({List<String>? ads, List<RuleConfig>? rules}) {
    _blockedHosts.clear();
    _groups.clear();
    try {
      final global = _RuleGroup(hosts: const []);
      if (ads != null) {
        for (final raw in ads) {
          _addAdPattern(raw, global);
        }
      }
      if (!global.isEmpty) _groups.add(global);

      if (rules != null) {
        for (final r in rules) {
          _addRuleConfig(r);
        }
      }
      if (enabled) {
        AppLog.instance.log(
            '[AdFilter] 规则已加载: hosts=${_blockedHosts.length} groups=${_groups.length}');
      }
    } catch (e) {
      // 兜底：绝不让规则加载异常影响到主流程
      AppLog.instance.log('[AdFilter] 规则加载异常: $e');
    }
  }

  /// 播放地址是否命中广告/黑名单规则。
  bool isBlocked(String url) {
    if (!enabled || url.isEmpty) return false;
    final host = _hostOf(url);
    for (final d in _blockedHosts) {
      if (host.isNotEmpty && (host == d || host.endsWith('.$d'))) return true;
    }
    for (final g in _groups) {
      if (!_hostMatches(host, g.hosts)) continue;
      for (final re in g.blockRegexes) {
        try {
          if (re.hasMatch(url)) return true;
        } catch (_) {
          // 单条匹配异常不影响其它规则
        }
      }
    }
    return false;
  }

  /// 对播放地址做正则替换（仅处理 `pattern#replacement` 形态的规则）。
  /// 未命中任何替换规则时返回原串。
  String rewrite(String url) {
    if (_groups.isEmpty || url.isEmpty) return url;
    var result = url;
    final host = _hostOf(url);
    for (final g in _groups) {
      if (!_hostMatches(host, g.hosts)) continue;
      for (final rw in g.rewrites) {
        try {
          if (rw.pattern.hasMatch(result)) {
            result = result.replaceAll(rw.pattern, rw.replacement);
          }
        } catch (_) {
          // 单条替换异常不影响其它规则
        }
      }
    }
    return result;
  }

  // ============================================================
  // 解析内部
  // ============================================================

  /// 解析单条 `ads` 字符串。
  void _addAdPattern(String raw, _RuleGroup global) {
    final p = raw.trim();
    if (p.isEmpty) return;
    if (p.startsWith('##')) {
      // `##selector` → 按正则处理
      final re = _tryCompile(p.substring(2));
      if (re != null) global.blockRegexes.add(re);
      return;
    }
    if (p.startsWith('||')) {
      final d = _normalizeDomain(p.substring(2));
      if (d.isNotEmpty) _addBlockedHost(d);
      return;
    }
    if (_looksLikeDomain(p)) {
      final d = _normalizeDomain(p);
      if (d.isNotEmpty) _addBlockedHost(d);
      return;
    }
    // 其它按正则尝试
    final re = _tryCompile(p);
    if (re != null) global.blockRegexes.add(re);
  }

  /// 解析单条 [RuleConfig]（rule + regex + filter 合并处理，host/hosts 决定作用域）。
  void _addRuleConfig(RuleConfig r) {
    final hosts = <String>[];
    final h = r.host?.trim();
    if (h != null && h.isNotEmpty) {
      final d = _normalizeDomain(h);
      if (d.isNotEmpty) hosts.add(d);
    }
    for (final hh in r.hosts ?? const <String>[]) {
      final d = _normalizeDomain(hh.trim());
      if (d.isNotEmpty) hosts.add(d);
    }

    final group = _RuleGroup(hosts: hosts);
    for (final p in <String>[
      ...?r.rule,
      ...?r.regex,
      ...?r.filter,
    ]) {
      _addRulePattern(p, group);
    }
    if (!group.isEmpty) _groups.add(group);
  }

  void _addRulePattern(String raw, _RuleGroup group) {
    final p = raw.trim();
    if (p.isEmpty) return;
    if (p.startsWith('||')) {
      final d = _normalizeDomain(p.substring(2));
      if (d.isNotEmpty) _addBlockedHost(d);
      return;
    }
    // `pattern#replacement` → 正则替换
    final hash = p.indexOf('#');
    if (hash > 0) {
      final re = _tryCompile(p.substring(0, hash));
      if (re != null) {
        group.rewrites.add(_Replacement(re, p.substring(hash + 1)));
      }
      return;
    }
    final re = _tryCompile(p);
    if (re != null) group.blockRegexes.add(re);
  }

  void _addBlockedHost(String domain) {
    if (!_blockedHosts.contains(domain)) _blockedHosts.add(domain);
  }

  RegExp? _tryCompile(String pattern) {
    final p = pattern.trim();
    if (p.isEmpty) return null;
    try {
      return RegExp(p, caseSensitive: false);
    } catch (e) {
      AppLog.instance.log('[AdFilter] 正则编译失败, 已跳过: $p');
      return null;
    }
  }

  bool _looksLikeDomain(String s) {
    return RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$').hasMatch(s);
  }

  /// 归一化域名：去掉 `||` 前缀、协议、路径/参数/锚点，小写。
  String _normalizeDomain(String raw) {
    var d = raw.trim().toLowerCase();
    if (d.startsWith('||')) d = d.substring(2);
    d = d.replaceFirst(RegExp(r'^[a-z]+://'), '');
    for (final sep in const ['/', '^', '?', '#', ' ']) {
      final i = d.indexOf(sep);
      if (i >= 0) d = d.substring(0, i);
    }
    return d;
  }

  String _hostOf(String url) {
    try {
      return Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    } catch (_) {
      return '';
    }
  }

  bool _hostMatches(String host, List<String> scope) {
    if (scope.isEmpty) return true; // 全局规则
    if (host.isEmpty) return false;
    for (final s in scope) {
      if (host == s || host.endsWith('.$s')) return true;
    }
    return false;
  }
}
