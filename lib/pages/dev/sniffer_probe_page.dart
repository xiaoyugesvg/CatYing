import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/rex/rex_player_page.dart';
import 'package:tvbox/services/media_resolver.dart';
import 'package:tvbox/services/media_sniff_service.dart';
import 'package:tvbox/services/parse_lines.dart';
import 'package:tvbox/services/platform_domains.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 「解析 / 嗅探测试」页（开发调试用）。
///
/// ── 2026-10-31 重写 ────────────────────────────────────────────
/// 上一版这里自己建 WebView、自己注入、自己计时 —— 和正式链路
/// `MediaSniffService` 是**两套代码**。结果就是「测试页能抓到、真播放抓不到」
/// 这种最难受的偏差，而且每修一次要改两处。
///
/// 现在本页只做三件事：
///   1. 调 `MediaResolver.resolve()`（完整链路）或 `MediaSniffService.sniffDetailed()`
///      （只看嗅探）—— 和真实播放**同一条代码路径**；
///   2. 把结果摊开：首选地址、全部候选、跟过的 iframe、原始事件；
///   3. 每条地址都能直接丢给播放器试播。
///
/// 隐形 WebView 由服务自己挂到 root Overlay 上（1×1、透明、IgnorePointer），
/// 本页不再持有 controller。
class SnifferProbePage extends StatefulWidget {
  const SnifferProbePage({super.key});

  @override
  State<SnifferProbePage> createState() => _SnifferProbePageState();
}

class _SnifferProbePageState extends State<SnifferProbePage> {
  final _urlCtrl = TextEditingController(
      text:
          'https://jx.muiu.site/?url=https://v.qq.com/x/cover/mzc00200803dr6b/g4102ay41nf.html');

  /// 测试页给的时间比正式链路（12s）宽一点：这里就是要看"到底抓得到什么"。
  static const Duration _sniffBudget = Duration(seconds: 24);

  // ── 解析测试 ──
  bool _parseRunning = false;
  String _parseStatus = '';
  String? _parseResult;

  // ── 嗅探测试 ──
  bool _sniffRunning = false;
  String _sniffStatus = '待开始';
  SniffResult? _sniff;
  bool _showLogs = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  // ============================================================
  // 解析测试：完整链路（抓页面 → 线路 → 嗅探兜底）
  // ============================================================
  Future<void> _testParse() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      AppToast.show('先填链接', '');
      return;
    }
    setState(() {
      _parseRunning = true;
      _parseResult = null;
      _parseStatus = '准备解析…';
    });
    // 解析线路懒同步：没读过就先读，订阅里的 parses 也拉一次
    try {
      final store = ParseLineStore.instance;
      await store.load();
      if (store.isEmpty) await store.ensureSyncedFromConfig();
    } catch (_) {}
    try {
      // 这里**不关**嗅探兜底：本按钮回答的问题是「真实播放能不能出地址」，
      // 所以必须和播放链路一致。只想单独看嗅探抓到什么，用「嗅探测试」。
      final r = await MediaResolver.instance.resolve(
        url,
        onProgress: (m) {
          if (mounted) setState(() => _parseStatus = m);
        },
      );
      if (!mounted) return;
      setState(() {
        _parseResult = r;
        _parseStatus =
            r == null ? '完整链路也没出直链（抓页面 + 线路 + 嗅探都试过了）' : '解析成功';
      });
    } catch (e) {
      if (mounted) setState(() => _parseStatus = '解析异常: $e');
    } finally {
      if (mounted) setState(() => _parseRunning = false);
    }
  }

  // ============================================================
  // 嗅探测试：只跑嗅探，把全过程摊开
  // ============================================================
  Future<void> _startSniff() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      AppToast.show('先填链接', '');
      return;
    }
    setState(() {
      _sniffRunning = true;
      _sniff = null;
      _showLogs = false;
      _sniffStatus = '准备嗅探…';
    });
    try {
      final r = await MediaSniffService.instance.sniffDetailed(
        url,
        budget: _sniffBudget,
        onProgress: (m) {
          if (mounted) setState(() => _sniffStatus = m);
        },
      );
      if (!mounted) return;
      setState(() {
        _sniff = r;
        if (r.ok) {
          _sniffStatus = '嗅探成功';
        } else if (r.candidates.isEmpty) {
          _sniffStatus = '没抓到任何地址（候选 0 条，跟过 ${r.frames.length} 个 iframe）';
        } else {
          _sniffStatus =
              '抓到 ${r.candidates.length} 条，但没有媒体直链（可能都在 iframe 里没跟到）';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _sniffStatus = '嗅探异常: $e');
    } finally {
      if (mounted) setState(() => _sniffRunning = false);
    }
  }

  /// 「停止」：置中止位，服务下一轮循环就跳出来（结果仍会返回）。
  void _stop() {
    if (_sniffRunning) {
      MediaSniffService.instance.cancel();
      setState(() => _sniffStatus = '正在收工…');
    }
  }

  // ============================================================
  // 播 / 复制
  // ============================================================
  void _play(String url) {
    final u = url.trim();
    if (u.isEmpty) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'dev:sniff-play'),
        builder: (_) => RexPlayerPage(title: '嗅探结果', url: u),
      ),
    );
  }

  void _copy(String s) {
    Clipboard.setData(ClipboardData(text: s));
    AppToast.show('已复制', '');
  }

  // ============================================================
  // UI
  // ============================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundSecondary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundSecondary,
        elevation: 0,
        title: const Text('解析 / 嗅探测试'),
      ),
      body: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final url = _urlCtrl.text.trim();
    final routeMode = url.isEmpty
        ? null
        : (isVideoPlatformUrl(url)
            ? '平台链接：建议先用「解析测试」走线路，直连嗅探多半被 DRM / 防盗链挡住'
            : '普通页面：直接嗅探抓取');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _urlCtrl,
            onChanged: (_) => setState(() {}),
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              labelText: '播放页 / 解析接口地址',
              hintText: 'https://…',
              isDense: true,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _parseRunning ? null : _testParse,
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('解析测试'),
              ),
              FilledButton.tonalIcon(
                onPressed: _sniffRunning ? null : _startSniff,
                icon: const Icon(Icons.travel_explore_rounded, size: 18),
                label: const Text('嗅探测试'),
              ),
              OutlinedButton(
                onPressed: _sniffRunning ? _stop : null,
                child: const Text('停止'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (_parseRunning || _sniffRunning)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (_parseRunning || _sniffRunning) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _parseRunning ? _parseStatus : _sniffStatus,
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
              ),
              if (_sniff?.candidates.isNotEmpty ?? false)
                Text('候选 ${_sniff!.candidates.length}',
                    style:
                        TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
            ],
          ),
          if (routeMode != null) ...[
            const SizedBox(height: 4),
            Text(routeMode,
                style: TextStyle(color: AppTheme.accentColor, fontSize: 11)),
          ],
          const SizedBox(height: 2),
          Text(
            '「解析测试」= 完整链路（抓页面 → 线路 → 嗅探兜底），跟真实播放一致；'
            '「嗅探测试」= 只看嗅探抓到什么，顺 iframe 最多跟 3 层。',
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    final r = _sniff;
    final hasParse = _parseStatus.isNotEmpty;
    if (!hasParse && r == null) {
      return Center(
        child: Text('点「解析测试」或「嗅探测试」开始',
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 13)),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
      children: [
        if (hasParse) ...[
          _sectionTitle('解析测试'),
          _ResultCard(
            url: _parseResult ?? _parseStatus,
            subtitle: _parseResult != null
                ? '$_parseStatus · 完整链路'
                : _parseStatus,
            highlight: _parseResult != null,
            placeholder: _parseResult == null,
            onPlay: _parseResult == null ? null : () => _play(_parseResult!),
            onCopy: _parseResult == null ? null : () => _copy(_parseResult!),
          ),
          const SizedBox(height: 14),
        ],
        if (r != null) ...[
          if (r.best != null) ...[
            _sectionTitle('嗅探首选'),
            _ResultCard(
              url: r.best!,
              badge: _kindOf(r, r.best!),
              subtitle: '直链 · 点右边可以直接播',
              highlight: true,
              onPlay: () => _play(r.best!),
              onCopy: () => _copy(r.best!),
            ),
            const SizedBox(height: 14),
          ],
          if (r.candidates.isNotEmpty) ...[
            _sectionTitle('候选地址（${r.candidates.length}）'),
            for (final c in r.candidates) ...[
              _ResultCard(
                url: c.url,
                badge: c.kind.isEmpty ? '?' : c.kind,
                subtitle: '${c.via.isEmpty ? "?" : c.via} · score ${c.score}'
                    '${c.isMedia ? " · 直链" : ""}',
                highlight: c.url == r.best,
                onPlay: c.isMedia ? () => _play(c.url) : null,
                onCopy: () => _copy(c.url),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 6),
          ],
          if (r.frames.isNotEmpty) ...[
            _sectionTitle('跟过的 iframe（${r.frames.length}）'),
            for (final f in r.frames) ...[
              _ResultCard(
                url: f,
                badge: 'iframe',
                subtitle: '壳页里的下一层地址',
                muted: true,
                onCopy: () => _copy(f),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 6),
          ],
          if (r.logs.isNotEmpty) ...[
            InkWell(
              onTap: () => setState(() => _showLogs = !_showLogs),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  children: [
                    Icon(
                      _showLogs
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: AppTheme.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text('原始事件（${r.logs.length}）',
                        style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
            if (_showLogs)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  r.logs.join('\n'),
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 10.5,
                      height: 1.5,
                      fontFamily: 'monospace'),
                ),
              ),
          ],
        ],
      ],
    );
  }

  String _kindOf(SniffResult r, String url) {
    for (final c in r.candidates) {
      if (c.url == url) return c.kind.isEmpty ? '?' : c.kind;
    }
    return '直链';
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 2),
        child: Text(t,
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      );
}

/// 一条地址卡片：徽标 + 地址 + 说明 + 播放 / 复制。
///
/// `placeholder` = 这条不是地址（比如"解析失败"的原因文字），不显示播放/复制。
class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.url,
    this.badge,
    this.subtitle,
    this.highlight = false,
    this.muted = false,
    this.placeholder = false,
    this.onPlay,
    this.onCopy,
  });

  final String url;
  final String? badge;
  final String? subtitle;
  final bool highlight;
  final bool muted;
  final bool placeholder;
  final VoidCallback? onPlay;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final borderColor =
        highlight ? AppTheme.accentColor : AppTheme.textTertiary;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: borderColor.withValues(alpha: highlight ? 1.0 : 0.18),
          width: highlight ? 1.0 : 0.8,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (badge != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(badge!,
                  style:
                      TextStyle(fontSize: 11, color: AppTheme.accentColor)),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  url,
                  maxLines: placeholder ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: placeholder
                        ? AppTheme.textSecondary
                        : (muted ? AppTheme.textSecondary : AppTheme.textPrimary),
                    fontSize: placeholder ? 12 : 11.5,
                    height: 1.35,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!,
                      style: TextStyle(
                          color: AppTheme.textTertiary, fontSize: 10.5)),
                ],
              ],
            ),
          ),
          if (onPlay != null)
            IconButton(
              onPressed: onPlay,
              icon: const Icon(Icons.play_circle_fill_rounded, size: 28),
              color: AppTheme.accentColor,
              tooltip: '用播放器试播',
              visualDensity: VisualDensity.compact,
            ),
          if (onCopy != null)
            IconButton(
              onPressed: onCopy,
              icon: const Icon(Icons.copy_rounded, size: 16),
              color: AppTheme.textSecondary,
              tooltip: '复制',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}
