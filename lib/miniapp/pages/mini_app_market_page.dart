import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import '../models/mini_app.dart';
import '../services/mini_app_service.dart';

/// 「小程序市场」页：列出市场清单（`{"apps":[…]}`）里的程序，点「安装」即下载安装。
///
/// 用户 2026-10-13：「链接导入后加载里面的小程序并且显示安装按钮，安装就是下载导入」。
/// 两种市场项都能装：
/// - `url` 指向 manifest.json（在线站点型）→ 记住远端页面，直接打开；
/// - `url` 指向 zip → 下载解包到本地再打开。
class MiniAppMarketPage extends StatefulWidget {
  /// 市场清单地址（用户导入的那个链接）
  final String marketUrl;

  /// 已经拉好的清单（导入时顺手解析过，避免重复下载）
  final List<MiniAppMarketEntry>? preloaded;

  const MiniAppMarketPage({
    super.key,
    required this.marketUrl,
    this.preloaded,
  });

  @override
  State<MiniAppMarketPage> createState() => _MiniAppMarketPageState();
}

class _MiniAppMarketPageState extends State<MiniAppMarketPage> {
  final _service = MiniAppService.instance;

  List<MiniAppMarketEntry>? _list;
  String? _error;
  bool _loading = true;

  /// 正在安装的 appId
  final _installing = <String>{};

  @override
  void initState() {
    super.initState();
    if (widget.preloaded != null && widget.preloaded!.isNotEmpty) {
      _list = widget.preloaded;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _service.fetchMarket(widget.marketUrl);
      if (!mounted) return;
      setState(() {
        _list = list;
        _loading = false;
        _error = (list == null || list.isEmpty) ? '这个地址不是小程序市场清单' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '下载失败: $e';
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
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text('小程序市场',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: Icon(Icons.refresh_rounded, color: AppTheme.textSecondary),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
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
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (c, i) => _tile(list[i]),
    );
  }

  Widget _tile(MiniAppMarketEntry e) {
    final installed = _service.isInstalled(e.appId);
    final busy = _installing.contains(e.appId);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: AppTheme.accentColor.withValues(alpha: 0.15),
            ),
            child: Icon(
              e.isZip ? Icons.folder_zip_outlined : Icons.language_rounded,
              size: 22,
              color: AppTheme.accentColor,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(e.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                    ),
                    if (e.version.isNotEmpty)
                      Text(e.version,
                          style: TextStyle(
                              color: AppTheme.textTertiary, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (e.author.isNotEmpty) e.author,
                    if (e.size > 0) '${(e.size / 1024).toStringAsFixed(0)} KB',
                    e.isZip ? 'zip 包' : '在线站点',
                  ].join(' · '),
                  style: TextStyle(color: AppTheme.textTertiary, fontSize: 11),
                ),
                if (e.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(e.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                          height: 1.3)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 62,
            child: installed
                ? TextButton(
                    onPressed: busy ? null : () => _install(e),
                    child: Text(busy ? '…' : '重装',
                        style: const TextStyle(fontSize: 12)),
                  )
                : FilledButton(
                    onPressed: busy ? null : () => _install(e),
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(62, 32),
                    ),
                    child: Text(busy ? '安装中' : '安装',
                        style: const TextStyle(fontSize: 12)),
                  ),
          ),
        ],
      ),
    );
  }
}
