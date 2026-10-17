import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/hiker_source.dart';
import '../services/hiker_prefs.dart';
import 'hiker_richtext.dart';
import 'hiker_widgets.dart';

// 富文本工具（hikerPlainText / hikerRichSpans / hikerRichIsActive …）对外转发，
// 老调用点继续从本文件 import 即可
export 'hiker_richtext.dart';

/// 海阔列表的**分块渲染**：按 `col_type` 还原官方布局。
///
/// 为什么必须做这件事（用户 2026-10-16：「海阔是将分类作为 tab 的，每个分类也有内容」）：
/// 海阔的「分类」不是 Legado 那种静态 `class_name` / `class_url`，而是**规则自己
/// 产出的条目**（`col_type: scroll_button` / `icon_small_4` / `flex_button`…），
/// 官方把它们渲染成**顶部的分类按钮行 / 图标行**，点一下就**就地换分类**（重跑规则）；
/// 原来我们一律按网格卡片渲染 ⇒ 分类混进内容里、还配着占位图。
///
/// 布局参数照官方 `ArticleColTypeEnum`（12 栅格：leftRight / spanCount）：
///   scroll_button / flex_button → 按钮（2 列）
///   icon_small_4 / icon_4 / icon_round_4 … → 一行 4 个图标
///   movie_1 → 单列大卡；movie_2 → 两列；movie_3 → 三列
///   text_* / text_center_1 → 文本行；long_text / rich_text → 段落
///   blank_block / line / line_blank → 间距与分割线
class HikerBlocks extends StatelessWidget {
  final List<HikerItem> items;

  /// 内容条目（movie_* / pic_* …）→ 详情页
  final void Function(HikerItem item) onTapItem;

  /// 分类 / 按钮 / 图标 / 文本类条目 → 就地切换（重跑规则）
  final void Function(HikerItem item) onTapAction;

  final void Function(HikerItem item)? onLongPress;

  /// `col_type: input` 条目（源自己放在首页的搜索框）
  final VoidCallback? onTapSearch;
  final double bottomPadding;

  /// 强制整行 `text_1` 按 N 列排（0 = 不动，用条目自己的 `col_type`）。
  ///
  /// 只给「工具入口弹窗」用：源里的设置项（接口域名 / 每页数量 / 列表样式…）
  /// 一行一个会拖很长，弹窗里多列更紧凑（用户 2026-10-16：先要两个、后改成三个）。
  /// 首页正常内容里保持原样（`text_1` 官方就是整行）。
  final int textColumns;

  /// 由外层滚动容器接管滚动（弹窗里用：内容少时弹窗就贴内容高度，不硬撑满）
  final bool shrinkWrap;

  const HikerBlocks({
    super.key,
    required this.items,
    required this.onTapItem,
    required this.onTapAction,
    this.onLongPress,
    this.onTapSearch,
    this.bottomPadding = 96,
    this.textColumns = 0,
    this.shrinkWrap = false,
  });

  @override
  Widget build(BuildContext context) {
    final runs = _runsOf(items, textColumns: textColumns);
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(0, 2, 0, bottomPadding),
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      itemCount: runs.length,
      itemBuilder: (_, i) => _buildRun(runs[i]),
    );
  }

  Widget _buildRun(_Run run) {
    switch (run.kind) {
      case _Kind.search:
        return _searchBox(run.items.first);
      case _Kind.chips:
        return _chips(run.items);
      case _Kind.icons4:
        return _icons(run.items, 4);
      case _Kind.icons3:
        return _icons(run.items, 3);
      case _Kind.cards1:
        return _cards(run.items, 1);
      case _Kind.cards2:
        return _cards(run.items, 2);
      case _Kind.cards3:
        return _cards(run.items, 3);
      case _Kind.text:
        return _textRow(run.items.first);
      case _Kind.text2:
        return _textCells(run.items, 2);
      case _Kind.text3:
        return _textCells(run.items, 3);
      case _Kind.text4:
        return _textCells(run.items, 4);
      case _Kind.text5:
        return _textCells(run.items, 5);
      case _Kind.paragraph:
        return _paragraph(run.items);
      case _Kind.gap:
        return _gap(run.items.first.colType);
    }
  }

  // ── 源自带的搜索框（`col_type: input`）──────────────────
  Widget _searchBox(HikerItem it) {
    final hint = it.desc.isNotEmpty
        ? hikerPlainText(it.desc)
        : (hikerPlainText(it.title).isEmpty ? '搜索' : hikerPlainText(it.title));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTapSearch,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(19),
          ),
          child: Row(
            children: [
              Icon(Icons.search_rounded,
                  size: 17, color: AppTheme.textTertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontFootnote),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 分类按钮行（海阔的「分类 tab」）────────────────────────
  Widget _chips(List<HikerItem> list) => hikerChipsRow(
        list,
        onTap: (it) => _tap(it, action: true),
        onLongPress: onLongPress,
      );

  // ── 图标行 / 图标块（分类入口）───────────────────────────
  Widget _icons(List<HikerItem> list, int perRow) => hikerIconRow(
        list,
        perRow,
        onTap: (it) => _tap(it, action: true),
        onLongPress: onLongPress,
      );

  // ── 内容卡片（按 span 分列）──────────────────────────────
  Widget _cards(List<HikerItem> list, int cols) {
    if (cols == 1) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Column(
          children: list
              .map((it) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _wideCard(it),
                  ))
              .toList(),
        ),
      );
    }
    final showDesc = HikerPrefs.instance.showDesc;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 12,
          crossAxisSpacing: 10,
          childAspectRatio: cols == 2 ? 0.72 : 0.58,
        ),
        itemCount: list.length,
        itemBuilder: (_, i) => HikerCard(
          item: list[i],
          showDesc: showDesc,
          onTap: () => _tap(list[i], action: false),
          onLongPress:
              onLongPress == null ? null : () => onLongPress!(list[i]),
        ),
      ),
    );
  }

  /// 单列大卡（movie_1：整宽图 + 标题/简介）
  Widget _wideCard(HikerItem it) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _tap(it, action: false),
      onLongPress: onLongPress == null ? null : () => onLongPress!(it),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: it.pic.isEmpty
                  ? Center(
                      child: Icon(Icons.movie_outlined,
                          size: 26, color: AppTheme.textTertiary))
                  : CachedNetworkImage(
                      imageUrl: it.pic,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Center(
                        child: Icon(Icons.broken_image_outlined,
                            size: 22, color: AppTheme.textTertiary),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(children: hikerRichSpans(it.title, _titleStyle())),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (it.desc.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        hikerPlainText(it.desc),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontCaption),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextStyle _titleStyle() => TextStyle(
      color: AppTheme.textPrimary,
      fontSize: AppTheme.fontFootnote,
      height: 1.25);

  // ── 文本行（text_1 / text_2 / text_3 / text_center_1 …）────
  Widget _textRow(HikerItem it) {
    final center = it.colType == 'text_center_1';
    final style = TextStyle(
      color: center ? AppTheme.textTertiary : AppTheme.textPrimary,
      fontSize: center ? AppTheme.fontCaption : AppTheme.fontFootnote,
      fontWeight: center ? FontWeight.w500 : FontWeight.w600,
    );
    final tappable = it.url.isNotEmpty && it.url != 'hiker://empty';
    return Padding(
      padding: EdgeInsets.fromLTRB(16, center ? 8 : 10, 16, center ? 8 : 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: !tappable ? null : () => _tap(it, action: true),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(children: hikerRichSpans(it.title, style)),
                textAlign: center ? TextAlign.center : TextAlign.start,
              ),
            ),
            if (it.desc.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  hikerPlainText(it.desc),
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption),
                ),
              ),
            if (tappable)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.chevron_right_rounded,
                    size: 16, color: AppTheme.textTertiary),
              ),
          ],
        ),
      ),
    );
  }

  // ── 多列文本按钮（text_2 / text_3 / text_4）────────────────
  //
  // 官方语义：一行摆 2/3/4 个等宽格子。源里典型就是
  //   `text_3` → 「收藏 / 历史 / 设置」三个工具入口（点一下就地切页）
  // 可点（有 url）的给成"按钮卡片"外观，纯文本的居中显示。
  Widget _textCells(List<HikerItem> list, int perRow) {
    final rows = <Widget>[];
    for (var i = 0; i < list.length; i += perRow) {
      final end = (i + perRow) > list.length ? list.length : (i + perRow);
      final slice = list.sublist(i, end);
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        // ⚠️ 不能用 `CrossAxisAlignment.stretch`：这块挂在 unbounded 高度的
        //    列表项里，stretch 会要求无限高（"BoxConstraints forces an infinite
        //    height"）。等宽由 Expanded 保证，高度交给各自内容。
        child: Row(
          children: [
            for (var j = 0; j < perRow; j++) ...[
              if (j > 0) const SizedBox(width: 8),
              Expanded(
                child: j < slice.length
                    ? _textCell(slice[j])
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  Widget _textCell(HikerItem it) {
    final tappable = it.url.isNotEmpty && it.url != 'hiker://empty';
    final style = TextStyle(
        color: AppTheme.textPrimary,
        fontSize: AppTheme.fontFootnote,
        fontWeight: FontWeight.w600);
    // 设置项这类条目 `desc` 就是**当前值**（接口域名 → https://…、每页数量 → 30）：
    // 多列之后一行放不下，改成"名称 / 值"两行居中，别把值丢了。
    final value = hikerPlainText(it.desc);
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text.rich(
          TextSpan(children: hikerRichSpans(it.title, style)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        if (value.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption),
          ),
        ],
      ],
    );
    if (!tappable) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: body,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _tap(it, action: true),
      child: Container(
        height: value.isEmpty ? 42 : 54,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: body,
      ),
    );
  }

  // ── 段落（long_text / rich_text）─────────────────────────
  Widget _paragraph(List<HikerItem> list) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: list
            .map((it) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text.rich(
                    TextSpan(
                        children: hikerRichSpans(
                            it.title,
                            TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: AppTheme.fontFootnote,
                                height: 1.6))),
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _gap(String type) {
    if (type == 'big_blank_block') return const SizedBox(height: 26);
    if (type == 'line') {
      return Divider(
          height: 14, thickness: 0.6, color: AppTheme.borderLight);
    }
    if (type == 'line_blank') {
      return Column(
        children: [
          const SizedBox(height: 6),
          Divider(height: 2, thickness: 0.6, color: AppTheme.borderLight),
          const SizedBox(height: 6),
        ],
      );
    }
    return const SizedBox(height: 12);
  }

  void _tap(HikerItem it, {required bool action}) {
    if (action) {
      onTapAction(it);
    } else {
      onTapItem(it);
    }
  }
}

// ============================================================
// 分块：把连续同类条目合成一块（等价官方 12 栅格里的行）
// ============================================================

enum _Kind {
  search,
  chips,
  icons4,
  icons3,
  cards1,
  cards2,
  cards3,
  text,
  text2,
  text3,
  text4,
  text5,
  paragraph,
  gap,
}

class _Run {
  final _Kind kind;
  final List<HikerItem> items;
  _Run(this.kind, this.items);
}

_Kind _kindOf(String colType) {
  switch (colType) {
    case 'input':
    case 'icon_1_search':
      return _Kind.search;
    case 'scroll_button':
    case 'flex_button':
      return _Kind.chips;
    case 'icon_small_4':
    case 'icon_4':
    case 'icon_4_card':
    case 'icon_round_4':
    case 'icon_round_small_4':
      return _Kind.icons4;
    case 'icon_small_3':
    case 'icon_2':
    case 'icon_2_round':
      return _Kind.icons3;
    case 'movie_1':
    case 'movie_1_left_pic':
    case 'movie_1_vertical_pic':
    case 'pic_1':
    case 'pic_1_full':
    case 'pic_1_card':
      return _Kind.cards1;
    case 'movie_2':
    case 'pic_2':
      return _Kind.cards2;
    case 'movie_3':
    case 'movie_3_marquee':
    case 'pic_3':
    case 'pic_3_square':
    case 'card_pic_3':
      return _Kind.cards3;
    // 官方 12 栅格（`ArticleColTypeEnum`）：
    //   text_1 / text_center_1 → spanCount 12 ⇒ 整行
    //   text_2 → 6 ⇒ 一行 2 个；text_3 → 4 ⇒ 一行 3 个；text_4 → 3 ⇒ 一行 4 个
    // 源里这些多列文本基本都是「收藏 / 历史 / 设置」这类**工具按钮**，
    // 官方摆成一行；之前一律按整行渲染 ⇒ 被拆成三行占满屏。
    case 'text_1':
    case 'text_center_1':
      return _Kind.text;
    case 'text_2':
      return _Kind.text2;
    case 'text_3':
      return _Kind.text3;
    case 'text_4':
      return _Kind.text4;
    // `text_5`（官方 5 列 / 每排 5 个）**原来没被识别** ⇒ 落到 `default` 被当成
    // `cards3`（3 列海报卡）渲染 ✗ —— 多个源（如「粉嫩小BB」）拿它当**分类**，
    // 于是"分类"变成一堆没有图的卡片格，用户看到的就是"分类没做成 tab"
    //（用户 2026-10-16）。这里补上识别，并让它在首页顶部走 tab 条（见
    // `splitLeadingNav` / `HikerNavStrip`）。
    case 'text_5':
      return _Kind.text5;
    case 'long_text':
    case 'rich_text':
      return _Kind.paragraph;
    case 'blank_block':
    case 'big_blank_block':
    case 'line':
    case 'line_blank':
      return _Kind.gap;
    case 'header':
    case 'footer':
      return _Kind.gap; // 官方内部用的分隔，等同于空白
    default:
      // 空 / 未知 col_type：官方 `getByCode` 也是回落到 movie_3
      return colType.isEmpty ? _Kind.cards3 : _Kind.cards3;
  }
}

/// 分块：连续同类条目合成一块。
///
/// [textColumns] > 0 时（工具入口弹窗），把相邻的整行 `text_1` 归并成 N 列
/// （一行 N 个卡片）—— 这样设置项就不用一行一个拖很长。
List<_Run> _runsOf(List<HikerItem> items, {int textColumns = 0}) {
  final runs = <_Run>[];
  for (final it in items) {
    final kind = _kindOf(it.colType);
    if (runs.isNotEmpty && runs.last.kind == kind && _mergable(kind)) {
      runs.last.items.add(it);
      continue;
    }
    runs.add(_Run(kind, [it]));
  }
  // 连续多个 gap 合成一个（源里常见 `blank_block` 连用）
  final merged = <_Run>[];
  for (final r in runs) {
    if (r.kind == _Kind.gap && merged.isNotEmpty && merged.last.kind == _Kind.gap) {
      continue;
    }
    merged.add(r);
  }
  // 工具弹窗：相邻的整行 `text_1` 归并成 N 列 ⇒ 渲染成一行 N 个卡片
  final wantKind = switch (textColumns) {
    2 => _Kind.text2,
    3 => _Kind.text3,
    4 => _Kind.text4,
    _ => null,
  };
  if (wantKind == null) return merged;
  final out = <_Run>[];
  for (final r in merged) {
    if (r.kind == _Kind.text) {
      if (out.isNotEmpty && out.last.kind == wantKind) {
        out.last.items.addAll(r.items);
      } else {
        out.add(_Run(wantKind, [...r.items]));
      }
      continue;
    }
    out.add(r);
  }
  return out;
}

/// 哪些块可以"连续同类合并"（卡片/按钮/图标是一行行排；文本与间距各占一块）
bool _mergable(_Kind k) =>
    k == _Kind.chips ||
    k == _Kind.icons4 ||
    k == _Kind.icons3 ||
    k == _Kind.cards1 ||
    k == _Kind.cards2 ||
    k == _Kind.cards3 ||
    // 多列文本要合并成一行（2/3/4/5 个一组），整行的 text_1 仍各占一块
    k == _Kind.text2 ||
    k == _Kind.text3 ||
    k == _Kind.text4 ||
    k == _Kind.text5 ||
    k == _Kind.paragraph;

// ============================================================
// 公共块：分类按钮行 / 图标行（页面顶部要**固定**显示时也用它们）
// ============================================================

/// 分类按钮行（`col_type: scroll_button` / `flex_button`）—— 海阔的「分类 tab」。
/// 源用 `‘‘’’<b>…</b>` 标记"当前选中"，这里解析成高亮样式。
Widget hikerChipsRow(
  List<HikerItem> list, {
  required void Function(HikerItem item) onTap,
  void Function(HikerItem item)? onLongPress,
}) {
  TextStyle style(bool active) => TextStyle(
        color: active ? AppTheme.accentOnSurface : AppTheme.textSecondary,
        fontSize: AppTheme.fontFootnote,
        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
      );
  return SizedBox(
    height: 38,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Row(
        children: [
          for (var i = 0; i < list.length; i++)
            Padding(
              padding: EdgeInsets.only(right: i == list.length - 1 ? 0 : 8),
              child: Builder(builder: (_) {
                final it = list[i];
                final active = hikerRichIsActive(it.title);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(it),
                  onLongPress: onLongPress == null ? null : () => onLongPress(it),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? AppTheme.accentColor.withValues(alpha: 0.16)
                          : AppTheme.backgroundTertiary,
                      borderRadius: BorderRadius.circular(16),
                      border: active
                          ? Border.all(
                              color: AppTheme.accentColor.withValues(alpha: 0.5))
                          : null,
                    ),
                    child: Text.rich(
                      TextSpan(children: hikerRichSpans(it.title, style(active))),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                );
              }),
            ),
        ],
      ),
    ),
  );
}

/// 图标行（`icon_small_4` / `icon_4` / `icon_small_3` 等）—— 很多源拿它当"分类入口"
Widget hikerIconRow(
  List<HikerItem> list,
  int perRow, {
  required void Function(HikerItem item) onTap,
  void Function(HikerItem item)? onLongPress,
}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
    child: LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth / perRow;
        return Wrap(
          runSpacing: 12,
          children: [
            for (final it in list)
              SizedBox(
                width: w,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(it),
                  onLongPress:
                      onLongPress == null ? null : () => onLongPress(it),
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 46,
                          height: 46,
                          color: AppTheme.backgroundTertiary,
                          child: it.pic.isEmpty
                              ? Icon(Icons.apps_rounded,
                                  size: 22, color: AppTheme.textTertiary)
                              : CachedNetworkImage(
                                  imageUrl: it.pic,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Icon(
                                      Icons.apps_rounded,
                                      size: 22,
                                      color: AppTheme.textTertiary),
                                ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text.rich(
                        TextSpan(
                            children: hikerRichSpans(
                                it.title,
                                TextStyle(
                                    color: hikerRichIsActive(it.title)
                                        ? AppTheme.accentOnSurface
                                        : AppTheme.textPrimary,
                                    fontSize: AppTheme.fontCaption,
                                    fontWeight: hikerRichIsActive(it.title)
                                        ? FontWeight.w700
                                        : FontWeight.w500))),
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// 页面顶部**固定**的分类区（统一渲染成 **tab 条**）。
///
/// 用户 2026-10-16：「海阔是将分类作为 tab 的」+「这个海阔没有将分类弄 tab 吗」
/// —— 固定在列表上方、不随内容滚走，点它就地换分类（见 `HikerHomePage._triggerAction`）。
///
/// ⚠️ 原来 `icon_*` 那一类（Apollo 风格源）走 [hikerIconRow] ⇒ 渲染成
/// **图标九宫格**（`Wrap`），跟"分类 tab"根本不是一回事 ⇒ 用户看到的就是
/// "分类没做成 tab"。现在两种都走 [hikerCategoryTabs]：
/// 横向可滑的单行 tab，有图标就带图标（18px），选中 = 强调色淡底 + 加粗描边。
class HikerNavStrip extends StatelessWidget {
  final List<HikerItem> items;
  final void Function(HikerItem item) onTap;

  const HikerNavStrip({super.key, required this.items, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return hikerCategoryTabs(items, onTap: onTap);
  }
}

/// 分类 **tab 条**：横向滚动 + 单行 + 选中高亮。
///
/// 与 [hikerChipsRow] 的区别只有一个：**条目带图标时把图标也画进 tab 里**
/// （在文字左边，18×18 圆角小图）—— 因为九宫格那类源的分类条目是
/// `icon_*`，`it.pic` 是有值的，直接扔掉图标反而不如带上。
Widget hikerCategoryTabs(
  List<HikerItem> list, {
  required void Function(HikerItem item) onTap,
  void Function(HikerItem item)? onLongPress,
}) {
  return SizedBox(
    height: 38,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Row(
        children: [
          for (var i = 0; i < list.length; i++)
            Padding(
              padding: EdgeInsets.only(right: i == list.length - 1 ? 0 : 8),
              child: Builder(builder: (_) {
                final it = list[i];
                final active = hikerRichIsActive(it.title);
                final fg = active
                    ? AppTheme.accentOnSurface
                    : AppTheme.textSecondary;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(it),
                  onLongPress:
                      onLongPress == null ? null : () => onLongPress(it),
                  child: Container(
                    // 有图标时左边只留 8，让图标跟文字凑得近一点
                    padding: EdgeInsets.only(
                        left: it.pic.isEmpty ? 14 : 8, right: 14),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? AppTheme.accentSurface
                          : AppTheme.backgroundTertiary,
                      borderRadius: BorderRadius.circular(16),
                      border: active
                          ? Border.all(
                              color:
                                  AppTheme.accentColor.withValues(alpha: 0.45))
                          : null,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (it.pic.isNotEmpty) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CachedNetworkImage(
                                imageUrl: it.pic,
                                fit: BoxFit.cover,
                                // 图挂了就只显示文字，不留空洞
                                errorBuilder: (_, _, _) =>
                                    const SizedBox.shrink(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text.rich(
                          TextSpan(
                              children: hikerRichSpans(
                                  it.title,
                                  TextStyle(
                                      color: fg,
                                      fontSize: AppTheme.fontFootnote,
                                      fontWeight: active
                                          ? FontWeight.w700
                                          : FontWeight.w500))),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
        ],
      ),
    ),
  );
}

/// 掐掉列表开头的"页面外壳"，只留内容 —— 给「工具入口弹窗」用。
///
/// 源被重跑后产出的列表**总是又把整页的头带一遍**：源自带的搜索框（`input`）+
/// 分类 chips + 「收藏 / 历史 / 设置」这一行（`text_2/3/4/5`）。弹窗里再显示这些
/// 没意义（实测「麻豆传媒AI」第二轮 n=24 里有 10 条都是壳，真正的设置项从
/// `text_center_1 程序设置` 才开始）。
List<HikerItem> stripLeadingShell(List<HikerItem> items) {
  var i = 0;
  while (i < items.length) {
    final k = _kindOf(items[i].colType);
    if (k == _Kind.search ||
        k == _Kind.chips ||
        k == _Kind.icons3 ||
        k == _Kind.icons4 ||
        k == _Kind.text2 ||
        k == _Kind.text3 ||
        k == _Kind.text4 ||
        k == _Kind.text5 ||
        k == _Kind.gap) {
      i++;
      continue;
    }
    break;
  }
  return items.sublist(i);
}

/// 把"顶部的分类区"从列表里摘出来（返回 pinned = 固定的那块，rest = 其余按序渲染）。
///
/// 判定：从前往后找**第一个** 分类行；它之前不能出现内容卡片
/// （出现卡片说明源是先内容后按钮，那就别固定了）。
///
/// ⚠️ 判定的 col_type 必须**覆盖源真正用的分类写法**，否则"分类"不会被固定、
///    也就不会走 tab 条。实测「粉嫩小BB」的分类是 `text_5`（2 排 × 5 个），
///    以前这里不认 ⇒ 它被当普通列表项渲染成卡片格（用户 2026-10-16：
///    「这个海阔没有将分类弄 tab 吗」）。
({List<HikerItem> pinned, List<HikerItem> rest}) splitLeadingNav(
    List<HikerItem> items) {
  var idx = -1;
  _Kind? kind;
  for (var i = 0; i < items.length; i++) {
    final k = _kindOf(items[i].colType);
    if (k == _Kind.cards1 || k == _Kind.cards2 || k == _Kind.cards3) break;
    if (k == _Kind.chips ||
        k == _Kind.icons4 ||
        k == _Kind.icons3 ||
        k == _Kind.text5) {
      idx = i;
      kind = k;
      break;
    }
  }
  if (idx < 0 || kind == null) {
    return (pinned: const <HikerItem>[], rest: items);
  }
  var end = idx;
  while (end + 1 < items.length && _kindOf(items[end + 1].colType) == kind) {
    end++;
  }
  return (
    pinned: items.sublist(idx, end + 1),
    rest: [...items.sublist(0, idx), ...items.sublist(end + 1)],
  );
}

// 富文本解析（`‘‘’’` / `““””` 两种标记、HTML 降级、极端色忽略）已抽到
// hiker_richtext.dart —— blocks 与 widgets 两边都要用，放这儿会循环 import。
// 通过下面的 export 继续对外提供，老调用点（本文件 / 详情页 / 测试）不用改。

