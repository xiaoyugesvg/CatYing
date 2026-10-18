import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import '../models/mini_app.dart';
import '../services/mini_app_service.dart';

/// 「程序 → 市场」Tab 的主体（无 Scaffold，直接嵌进程序页）。
///
/// 2026-10-13 改版（对齐用户给的参考图）：
///   · 顶部一行：**市场地址（JSON）输入框 + 「加载」按钮**（地址会记住，下次自动填回）
///   · 下面是市场条目列表，每条是**行式卡片**：
///     彩色首字图标 · 名称 · `v版本 · 作者` · 描述 · 右侧「安装 / 重装」药丸按钮
///
/// 与旧版独立路由页的区别：不再自带 AppBar/Scaffold，因为参考图里"市场"
/// 是程序页的一个 Tab，不是二级页面。
class MiniAppMarketView extends StatefulWidget {
  /// 初始市场地址（从「添加程序 → 小程序市场」导进来时带过来；空则用上次保存的）
  final String? initialUrl;

  /// 已解析好的清单（导入时顺带解析过 → 直接用，省一次重复下载）
  final List<MiniAppMarketEntry>? initialList;

  /// 安装成功回调（列表页用来刷新「已安装」那一屏）
  final VoidCallback? onInstalled;

  const MiniAppMarketView({
    super.key,
    this.initialUrl,
    this.initialList,
    this.onInstalled,
  });

  @override
  State<MiniAppMarketView> createState() => MiniAppMarketViewState();
}

class MiniAppMarketViewState extends State<MiniAppMarketView> {
  final _service = MiniAppService.instance;
  final _urlCtrl = TextEditingController();

  List<MiniAppMarketEntry>? _list;
  String? _error;
  bool _loading = false;

  /// 当前清单属于哪个市场地址（换地址时先清旧清单，避免"地址已换、列表还是旧的"）
  String _loadedUrl = '';

  /// 载入序号：快速换地址/连点加载时，旧响应一律丢弃
  int _loadSeq = 0;

  /// 正在安装的 appId
  final _installing = <String>{};

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = (widget.initialUrl?.trim().isNotEmpty ?? false)
        ? widget.initialUrl!.trim()
        : _service.marketUrl;
    final pre = widget.initialList;
    if (pre != null && pre.isNotEmpty) {
      // 导入时已解析过 → 直接用，不再下载；地址也顺手记住
      _list = pre;
      _loadedUrl = _urlCtrl.text.trim();
      if (_urlCtrl.text.isNotEmpty) _service.setMarketUrl(_urlCtrl.text);
    } else if (_urlCtrl.text.isNotEmpty) {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant MiniAppMarketView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 「添加程序」又导了一个不同的市场地址 → 换地址并重新加载
    final incoming = widget.initialUrl?.trim() ?? '';
    if (incoming.isEmpty || incoming == _urlCtrl.text.trim()) return;
    _urlCtrl.text = incoming;
    final pre = widget.initialList;
    if (pre != null && pre.isNotEmpty) {
      setState(() {
        _list = pre;
        _loadedUrl = incoming;
        _error = null;
        _loading = false;
      });
      _service.setMarketUrl(incoming);
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      AppToast.message('先填市场地址');
      return;
    }
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
      // 换了地址：先清掉旧地址的清单，别让两个市场的条目混在一屏
      if (url != _loadedUrl) _list = null;
    });
    // 记住地址：下次进「市场」自动填回并加载
    await _service.setMarketUrl(url);
    try {
      final list = await _service.fetchMarket(url);
      // 期间又换过地址/重新加载 → 这次结果作废
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _list = list;
        _loadedUrl = url;
        _loading = false;
        _error = (list == null || list.isEmpty) ? '这个地址不是小程序市场清单' : null;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _error = '加载失败: $e';
      });
    }
  }

  Future<void> _install(MiniAppMarketEntry e) async {
    if (_installing.contains(e.appId)) return;
    setState(() => _installing.add(e.appId));
    final r = await _service.installMarketEntry(e);
    if (!mounted) return;
    setState(() => _installing.remove(e.appId));
    AppToast.message(r.ok ? '已安装「${e.name}」' : (r.error ?? '安装失败'));
    if (r.ok) {
      await _service.ensureLoaded();
      widget.onInstalled?.call();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _addressRow(),
        // 已有清单时重新加载：顶部细进度条，避免"点了加载没反应"
        if (_loading && (_list?.isNotEmpty ?? false))
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingMD, 8, AppTheme.spacingMD, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                minHeight: 2,
                color: AppTheme.accentColor,
                backgroundColor:
                    AppTheme.textTertiary.withValues(alpha: 0.18),
              ),
            ),
          ),
        const SizedBox(height: 10),
        Expanded(child: _body()),
      ],
    );
  }

  /// 市场地址（JSON）行：圆角输入框 + 「加载」按钮（对齐参考图 1）
  Widget _addressRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMD),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: '市场地址（JSON）',
                hintStyle: TextStyle(color: AppTheme.textTertiary, fontSize: 13),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppTheme.borderMedium),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppTheme.borderMedium),
                ),
              ),
              onSubmitted: (_) => _load(),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 42,
            child: FilledButton(
              onPressed: _loading ? null : _load,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accentColor,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(_loading ? '加载中' : '加载',
                  style: const TextStyle(fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && (_list == null || _list!.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }

    final err = _error;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.storefront_outlined,
                  size: 40, color: AppTheme.textTertiary),
              const SizedBox(height: 10),
              Text(err,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSecondary)),
              const SizedBox(height: 14),
              TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final list = _list ?? const <MiniAppMarketEntry>[];
    if (list.isEmpty) {
      return Center(
        child: Text('填上面的地址，点「加载」拉取市场清单',
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 13)),
      );
    }

    return ListView.separated(
      // 用户 2026-10-13：底部留白加大——原来只留 24，列表最后几条会被
      // 底部悬浮菜单栏遮住一部分。这里放到 130（菜单栏高度 + 余量），
      // 保证能完整滑到底、最后一项也露在外面。
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingMD, 0, AppTheme.spacingMD, 130),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (c, i) => _tile(list[i]),
    );
  }

  /// 市场条目：**行式卡片**（对齐参考图 1）
  Widget _tile(MiniAppMarketEntry e) {
    final installed = _service.isInstalled(e.appId);
    final busy = _installing.contains(e.appId);
    final tint = _tintFor(e.appId);
    final initial = e.name.isNotEmpty ? e.name.characters.first : '程';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 彩色首字图标（参考图里每条颜色不同）
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: tint,
            ),
            child: Text(
              initial,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                // 「v版本 · 作者」—— 与参考图一致的一行小字
                Text(
                  [
                    if (e.version.isNotEmpty) 'v${e.version}',
                    if (e.author.isNotEmpty) e.author,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textTertiary, fontSize: 11),
                ),
                if (e.description.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(e.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                          height: 1.35)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          // 「安装 / 重装」药丸按钮
          SizedBox(
            height: 32,
            child: FilledButton(
              onPressed: busy ? null : () => _install(e),
              style: FilledButton.styleFrom(
                backgroundColor: installed
                    ? tint.withValues(alpha: 0.22)
                    : AppTheme.accentColor,
                foregroundColor: installed ? tint : Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: Text(busy ? '…' : (installed ? '重装' : '安装'),
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  static const _tints = <Color>[
    Color(0xFF4FC3F7), // 蓝
    Color(0xFF9575CD), // 紫
    Color(0xFF66BB6A), // 绿
    Color(0xFFFFA726), // 橙
    Color(0xFFEF5350), // 红
    Color(0xFF26A69A), // 青
  ];

  /// 按 appId 稳定取色（不用 String.hashCode：不保证跨进程稳定）
  Color _tintFor(String id) {
    var h = 0;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _tints[h % _tints.length];
  }
}
