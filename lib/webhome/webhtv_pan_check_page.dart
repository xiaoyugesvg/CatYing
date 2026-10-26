import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 「Webhtv → 网盘链接检测」（第 4 步，用户 2026-10-15）。
///
/// 对齐 WebHomeTV 的「网盘检测」：**内置网盘分享链接有效性检测**。
///
/// ── 判定口径（先说清，不谎报）──────────────────────────────────
///   · **识别**：按域名/协议把链接归类（夸克 / 阿里 / 百度 / UC / 天翼 / 迅雷 /
///     123 / 115 / 移动云盘 / 磁力 / ed2k …），并抽出分享 ID。
///   · **探测**：对 http(s) 分享链发一次 GET（跟随重定向），看
///     ① HTTP 码 ② 正文前几 KB 是否命中"失效特征词" ③ 是否命中"需登录特征词"。
///   · **磁力 / ed2k**：不走网络，纯本地结构校验（btih 长度、ed2k 字段数）。
///
///   ⇒ 这是「**可达性 + 失效特征词**」判定，等价于"打开这个分享页会不会看到
///     失效提示"，**不等于**各平台官方 API 校验：需要登录态的盘（百度等）
///     会显示「需登录」，我们不会把"打不开"说成"有效"。
///     要真·官方校验得逐个平台接 API/登录态 —— 那是后续单独的事。
class WebhtvPanCheckPage extends StatefulWidget {
  const WebhtvPanCheckPage({super.key});

  @override
  State<WebhtvPanCheckPage> createState() => _WebhtvPanCheckPageState();
}

/// 单条检测结果
class _PanResult {
  _PanResult(this.raw, this.platform, this.status, this.detail);
  final String raw;
  final String platform;
  /// ok / dead / login / unknown / localOk / localBad
  final String status;
  final String detail;
}

class _WebhtvPanCheckPageState extends State<WebhtvPanCheckPage> {
  final _ctrl = TextEditingController();
  final _results = <_PanResult>[];
  bool _busy = false;
  int _done = 0;
  int _total = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ============================================================
  // 规则表
  // ============================================================

  /// 平台识别：顺序即匹配顺序（先具体后笼统）
  static const List<(String, List<String>)> _platforms = [
    ('夸克', ['pan.quark.cn']),
    ('阿里云盘', ['alipan.com', 'aliyundrive.com']),
    ('百度网盘', ['pan.baidu.com', 'yun.baidu.com', 'eyun.baidu.com']),
    ('UC', ['drive.uc.cn', 'fast.uc.cn']),
    ('天翼云盘', ['cloud.189.cn']),
    ('迅雷云盘', ['pan.xunlei.com']),
    ('123云盘', ['123pan.com', '123684.com', '123865.com', '123912.com']),
    ('115', ['115.com', 'anxia.com', '115cdn.com']),
    ('移动云盘', ['caiyun.139.com']),
    ('和彩云', ['cloud.139.com']),
    ('光雅', ['guangya']),
  ];

  /// 失效特征词（正文里出现即判定"已失效"）
  static const List<String> _deadHints = [
    '分享已失效',
    '链接不存在',
    '分享不存在',
    '已取消分享',
    '该分享已被取消',
    '文件已删除',
    '已被删除',
    '分享已过期',
    '来晚了',
    '资源已失效',
    '分享的文件已经被取消',
    '你访问的页面不存在',
  ];

  /// 需登录 / 需验证特征词
  static const List<String> _loginHints = [
    '请先登录',
    '登录后查看',
    '请输入提取码',
    '访问码',
    '验证码',
    'sign in',
    'log in',
  ];

  static String _platformOf(String text) {
    final t = text.toLowerCase();
    if (t.startsWith('magnet:')) return '磁力';
    if (t.startsWith('ed2k:')) return 'ed2k';
    for (final (name, hosts) in _platforms) {
      for (final h in hosts) {
        if (t.contains(h)) return name;
      }
    }
    // 兜底：从 http(s) 里取 host
    final u = Uri.tryParse(text);
    if (u != null && u.host.isNotEmpty) return u.host;
    return '链接';
  }

  /// 抽出链接（一行里可能带中文说明 + 提取码）
  static String _extractUrl(String line) {
    final t = line.trim();
    if (t.isEmpty) return '';
    final m = RegExp(r'(magnet:\?[^\s]+|ed2k://[^\s]+|https?://[^\s，,）)】"<>]+)')
        .firstMatch(t);
    return m?.group(1) ?? t;
  }

  // ============================================================
  // 检测
  // ============================================================

  Future<void> _check() async {
    final lines = _ctrl.text
        .split(RegExp(r'[\n\r]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      AppToast.message('先粘贴链接（一行一条）');
      return;
    }
    setState(() {
      _busy = true;
      _results.clear();
      _done = 0;
      _total = lines.length;
    });

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 14),
      followRedirects: true,
      responseType: ResponseType.plain,
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      },
    ));
    // 与全项目一致：跟随「设置 → 网络代理」
    applyGlobalProxy(dio);

    // 并发 4 条，避免一次打太多
    const window = 4;
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= lines.length) return;
        final r = await _checkOne(dio, lines[i]);
        if (!mounted) return;
        setState(() {
          _results.add(r);
          _done++;
        });
      }
    }

    try {
      await Future.wait(List.generate(window, (_) => worker()));
    } finally {
      dio.close(force: true);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_PanResult> _checkOne(Dio dio, String line) async {
    final url = _extractUrl(line);
    final plat = _platformOf(url);

    // 磁力 / ed2k：本地结构校验
    if (plat == '磁力') {
      final m = RegExp(r'btih:([0-9a-fA-F]{40}|[a-zA-Z2-7]{32})').firstMatch(url);
      return _PanResult(line, plat,
          m != null ? 'localOk' : 'localBad',
          m != null ? 'BTIH 结构正常（未联网校验做种）' : 'BTIH 不合法（应为 40 位 hex 或 32 位 base32）');
    }
    if (plat == 'ed2k') {
      final parts = url.split('|').where((e) => e.isNotEmpty).toList();
      final ok = url.startsWith('ed2k://|file|') && parts.length >= 4;
      return _PanResult(line, plat, ok ? 'localOk' : 'localBad',
          ok ? 'ed2k 结构正常（未联网校验源）' : 'ed2k 结构不完整');
    }

    if (!url.startsWith('http')) {
      return _PanResult(line, plat, 'unknown', '不是 http(s)/磁力/ed2k 链接');
    }

    try {
      final resp = await dio.get<String>(url);
      final code = resp.statusCode ?? 0;
      final body = (resp.data ?? '');
      final head = body.length > 20000 ? body.substring(0, 20000) : body;
      final low = head.toLowerCase();

      if (code == 404 || code == 410) {
        return _PanResult(line, plat, 'dead', 'HTTP $code');
      }
      for (final h in _deadHints) {
        if (head.contains(h)) {
          return _PanResult(line, plat, 'dead', '页面提示「$h」');
        }
      }
      if (code == 401 || code == 403) {
        return _PanResult(line, plat, 'login', 'HTTP $code（需登录 / 被风控）');
      }
      for (final h in _loginHints) {
        if (low.contains(h.toLowerCase())) {
          return _PanResult(line, plat, 'login', '页面要求「$h」');
        }
      }
      if (code >= 200 && code < 400) {
        return _PanResult(line, plat, 'ok', 'HTTP $code（未命中失效特征）');
      }
      return _PanResult(line, plat, 'unknown', 'HTTP $code');
    } on DioException catch (e) {
      return _PanResult(line, plat, 'unknown',
          '请求失败：${e.type.name}${e.message == null ? '' : '（${e.message}）'}');
    } catch (e) {
      return _PanResult(line, plat, 'unknown', '请求失败：$e');
    }
  }

  // ============================================================
  // UI
  // ============================================================

  static (IconData, Color, String) _styleOf(String status) => switch (status) {
        'ok' => (Icons.check_circle_rounded, const Color(0xFF34C759), '有效'),
        'localOk' => (Icons.check_circle_rounded, const Color(0xFF34C759), '结构正常'),
        'dead' => (Icons.cancel_rounded, const Color(0xFFE8463A), '已失效'),
        'localBad' => (Icons.cancel_rounded, const Color(0xFFE8463A), '格式错误'),
        'login' => (Icons.lock_rounded, const Color(0xFFEFAA17), '需登录'),
        _ => (Icons.help_outline_rounded, const Color(0xFF8E8E93), '未知'),
      };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppTheme.textPrimary;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : AppTheme.textSecondary;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        iconTheme: IconThemeData(color: fg),
        title: Text('网盘链接检测',
            style: TextStyle(
                color: fg,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.w600)),
        actions: [
          if (_results.isNotEmpty)
            IconButton(
              tooltip: '复制结果',
              onPressed: () {
                final txt = _results
                    .map((r) {
                      final (_, _, label) = _styleOf(r.status);
                      return '[$label] ${r.platform} ${r.raw}\n    ${r.detail}';
                    })
                    .join('\n');
                Clipboard.setData(ClipboardData(text: txt));
                AppToast.message('结果已复制');
              },
              icon: Icon(Icons.copy_all_rounded, color: fg),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          TextField(
            controller: _ctrl,
            maxLines: 5,
            style: TextStyle(fontSize: AppTheme.fontFootnote, color: fg),
            decoration: InputDecoration(
              hintText: '一行一条，可直接整段粘贴（含提取码也没关系）\n'
                  'https://pan.quark.cn/s/xxxx\n'
                  'magnet:?xt=urn:btih:xxxx\n'
                  'ed2k://|file|name|size|hash|/',
              hintStyle: TextStyle(fontSize: AppTheme.fontCaption, color: sub),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accentSurface,
                    foregroundColor: AppTheme.accentOnSurface,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  onPressed: _busy ? null : _check,
                  child: Text(_busy ? '检测中 $_done/$_total' : '开始检测'),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _ctrl.clear();
                          _results.clear();
                          _done = _total = 0;
                        }),
                child: Text('清空',
                    style: TextStyle(color: AppTheme.textTertiary)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '判定口径：http(s) 分享链发一次 GET，看 HTTP 码 + 页面里的失效/需登录特征词；'
            '磁力与 ed2k 只做本地结构校验。'
            '⚠️ 这不是各平台官方 API 校验 —— 需要登录态的盘会显示「需登录」，'
            '我们不会把打不开的链接说成有效。',
            style:
                TextStyle(fontSize: AppTheme.fontCaption, color: sub, height: 1.5),
          ),
          const SizedBox(height: 14),
          if (_results.isEmpty && !_busy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text('还没有结果',
                    style:
                        TextStyle(fontSize: AppTheme.fontSubhead, color: sub)),
              ),
            )
          else
            for (final r in _results) _card(r, fg, sub, isDark),
        ],
      ),
    );
  }

  Widget _card(_PanResult r, Color fg, Color sub, bool isDark) {
    final (icon, color, label) = _styleOf(r.status);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFF4F5F7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: color)),
              const SizedBox(width: 8),
              Text(r.platform,
                  style:
                      TextStyle(fontSize: AppTheme.fontCaption, color: sub)),
            ],
          ),
          const SizedBox(height: 4),
          Text(r.raw,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: AppTheme.fontCaption, color: fg)),
          const SizedBox(height: 2),
          Text(r.detail,
              style:
                  TextStyle(fontSize: AppTheme.fontCaption, color: sub)),
        ],
      ),
    );
  }
}
