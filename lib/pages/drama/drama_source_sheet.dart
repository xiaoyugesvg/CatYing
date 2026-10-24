import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/theme.dart';
import '../../models/source_bean.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/card_action_sheet.dart';

/// 短剧「切换源」面板 —— 与影视的 `SourceSwitchSheet` 同一套能力：
///   一行两列网格 / 单列列表切换、搜索、定位当前源、排序、长按卡片菜单。
///
/// 单独拆一个文件：`view.dart` 已经够长，这种纯选择面板塞回去只会更难读。
class DramaSourceSheet extends StatefulWidget {
  const DramaSourceSheet({
    super.key,
    required this.sources,
    required this.cachedKeys,
    required this.currentKey,
  });

  /// 全部可选源
  final List<SourceBean> sources;

  /// 已经扫出过短剧分类的源（标「短剧」徽章 + 缓存优先排序）
  final Set<String> cachedKeys;

  /// 当前短剧页正在看的源
  final String? currentKey;

  /// 弹出并返回用户选中的源（null = 取消）
  static Future<SourceBean?> show(
    BuildContext context, {
    required List<SourceBean> sources,
    required Set<String> cachedKeys,
    required String? currentKey,
  }) {
    return showModalBottomSheet<SourceBean>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DramaSourceSheet(
        sources: sources,
        cachedKeys: cachedKeys,
        currentKey: currentKey,
      ),
    );
  }

  @override
  State<DramaSourceSheet> createState() => _DramaSourceSheetState();
}

/// 排序方式
enum _SrcSort {
  cached('缓存优先'),
  name('名称'),
  origin('原顺序');

  const _SrcSort(this.label);
  final String label;
}

class _DramaSourceSheetState extends State<DramaSourceSheet> {
  final _kwCtrl = TextEditingController();
  final _scroll = ScrollController();

  String _kw = '';

  /// true = 一行两列（默认，与影视一致），false = 单列
  bool _grid = true;

  _SrcSort _sort = _SrcSort.cached;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;
  Color get _line => _isDark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);
  Color get _tile => _isDark
      ? Colors.white.withValues(alpha: 0.05)
      : Colors.black.withValues(alpha: 0.025);
  Color get _accent => AppTheme.accentOnSurface;

  @override
  void dispose() {
    _kwCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _hasDrama(SourceBean s) => widget.cachedKeys.contains(s.key);

  /// 过滤 + 排序后的源（列表与「定位」共用同一份口径，否则定位会偏）
  List<SourceBean> get _shown {
    Iterable<SourceBean> it = widget.sources;
    if (_kw.isNotEmpty) {
      final k = _kw.toLowerCase();
      it = it.where((s) => s.name.toLowerCase().contains(k));
    }
    final list = it.toList();
    switch (_sort) {
      case _SrcSort.cached:
        list.sort((a, b) {
          final aa = _hasDrama(a) ? 0 : 1;
          final bb = _hasDrama(b) ? 0 : 1;
          return aa - bb;
        });
        break;
      case _SrcSort.name:
        list.sort((a, b) => a.name.compareTo(b.name));
        break;
      case _SrcSort.origin:
        break;
    }
    return list;
  }

  /// 滚到当前源（用户要的「定位」）
  void _locate() {
    final key = widget.currentKey;
    if (key == null) return;
    final list = _shown;
    final idx = list.indexWhere((s) => s.key == key);
    if (idx < 0) {
      // 被搜索词过滤掉了 → 清空搜索再定位
      if (_kw.isNotEmpty) {
        _kwCtrl.clear();
        setState(() => _kw = '');
        WidgetsBinding.instance.addPostFrameCallback((_) => _locate());
      }
      return;
    }
    if (!_scroll.hasClients) return;
    final panelW = MediaQuery.of(context).size.width;
    double offset;
    if (_grid) {
      // 与下面的网格参数保持一致：左右 16、间距 10、纵横比 3.4、行距 8
      final itemW = (panelW - 32 - 10) / 2;
      final rowH = itemW / 3.4 + 8;
      offset = (idx ~/ 2) * rowH;
    } else {
      offset = idx * 50.0;
    }
    final pos = _scroll.position;
    _scroll.animateTo(
      (offset - pos.viewportDimension / 3)
          .clamp(0.0, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  /// 长按卡片 → 卡片式菜单（一行两个）
  Future<void> _menu(SourceBean s) async {
    HapticFeedback.mediumImpact();
    await showCardActions(
      context,
      title: s.name,
      subtitle: _hasDrama(s) ? '已缓存短剧分类' : s.api,
      actions: [
        CardAction(
          icon: Icons.play_circle_outline_rounded,
          label: '用这个',
          onTap: () => Navigator.pop(context, s),
        ),
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () {
            Clipboard.setData(ClipboardData(text: '${s.name}\n${s.api}'));
            AppToast.show('已复制源地址', '');
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final h = MediaQuery.of(context).size.height;
    return Container(
      height: h * 0.62,
      decoration: BoxDecoration(
        color: _isDark ? const Color(0xFF1B1B1F) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: _line, width: 0.5),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: _sub.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // ── 标题 + 定位 + 视图 ──────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
              child: Row(
                children: [
                  Text('切换源',
                      style: TextStyle(
                          color: _fg,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  _roundBtn(Icons.my_location_rounded, '定位当前源', _locate),
                  const SizedBox(width: 8),
                  _roundBtn(
                    _grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                    _grid ? '单列' : '两列',
                    () => setState(() => _grid = !_grid),
                  ),
                ],
              ),
            ),
            // ── 搜索 ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: 34,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(color: _line, width: 0.6),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 10),
                    Icon(Icons.search_rounded, size: 15, color: _sub),
                    const SizedBox(width: 5),
                    Expanded(
                      child: TextField(
                        controller: _kwCtrl,
                        style: TextStyle(
                            color: _fg, fontSize: AppTheme.fontSubhead),
                        onChanged: (v) => setState(() => _kw = v.trim()),
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: '搜索源…',
                          hintStyle:
                              TextStyle(color: _sub, fontSize: 12.5),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 8),
                        ),
                      ),
                    ),
                    if (_kw.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          _kwCtrl.clear();
                          setState(() => _kw = '');
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child:
                              Icon(Icons.cancel, size: 14, color: _sub),
                        ),
                      ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            // ── 排序 ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
              child: Row(
                children: [
                  for (final s in _SrcSort.values) ...[
                    GestureDetector(
                      onTap: () => setState(() => _sort = s),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: _sort == s
                              ? _accent.withValues(alpha: 0.14)
                              : _tile,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          s.label,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: _sort == s
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: _sort == s ? _accent : _sub,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  const Spacer(),
                  Text('${shown.length} 个',
                      style: TextStyle(
                          color: _sub, fontSize: AppTheme.fontCaption)),
                ],
              ),
            ),
            // ── 源列表 ──────────────────────────────────────────
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(_kw.isEmpty ? '这里还没有源' : '未找到匹配的源',
                          style: TextStyle(
                              color: _sub,
                              fontSize: AppTheme.fontSubhead)),
                    )
                  : _grid
                      ? GridView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 10,
                            childAspectRatio: 3.4,
                          ),
                          itemCount: shown.length,
                          itemBuilder: (_, i) => _tileCard(shown[i]),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          itemCount: shown.length,
                          itemBuilder: (_, i) => _rowCard(shown[i]),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  /// 两列网格卡片（与影视源面板同版式）
  Widget _tileCard(SourceBean s) {
    final on = s.key == widget.currentKey;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context, s),
      onLongPress: () => _menu(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: on ? _accent.withValues(alpha: 0.12) : _tile,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: on ? _accent.withValues(alpha: 0.40) : _line,
            width: on ? 1 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(on ? Icons.check_circle_rounded : Icons.live_tv_rounded,
                size: 16,
                color: on ? _accent : _sub.withValues(alpha: 0.8)),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                s.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: on ? _fg : _sub,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (_hasDrama(s))
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('短剧',
                    style: TextStyle(
                        color: _accent,
                        fontSize: 9,
                        fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ),
    );
  }

  /// 单列行卡片
  Widget _rowCard(SourceBean s) {
    final on = s.key == widget.currentKey;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(context, s),
        onLongPress: () => _menu(s),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: on ? _accent.withValues(alpha: 0.12) : _tile,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: on ? _accent.withValues(alpha: 0.40) : _line,
              width: on ? 1 : 0.5,
            ),
          ),
          child: Row(
            children: [
              Icon(on ? Icons.check_circle_rounded : Icons.live_tv_rounded,
                  size: 17, color: on ? _accent : _sub),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: on ? _fg : _sub,
                    fontSize: AppTheme.fontBody,
                    fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (_hasDrama(s))
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('短剧',
                      style: TextStyle(
                          color: _accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                ),
              const SizedBox(width: 4),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _menu(s),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 6),
                  child: Icon(Icons.more_horiz_rounded,
                      size: 18, color: _sub),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roundBtn(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: _tile, shape: BoxShape.circle),
          child: Icon(icon, size: 16, color: _sub),
        ),
      ),
    );
  }
}
