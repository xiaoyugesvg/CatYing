import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../common/theme.dart';
import '../models/source_bean.dart';
import '../services/api_config.dart';

/// 源切换弹窗（2026-09-26 新增）
///
/// 替代首页左上角原来的 PopupMenuButton 简单菜单，样式对齐参考截图：
/// - 顶部搜索框（"搜索源..."）实时过滤
/// - 右上圆形按钮切换 单列列表 / 双排网格
/// - 源列表可下滑滚动，每项带选中圈（实心=当前源）
/// - 点击源 → setHomeSource + 关闭弹窗，由调用方刷新首页
class SourceSwitchSheet extends StatefulWidget {
  /// 选中源并关闭弹窗后回调（用于刷新首页内容）
  final VoidCallback? onSelected;

  const SourceSwitchSheet({super.key, this.onSelected});

  /// 便捷弹出：返回 true 表示用户确实切换了源
  static Future<bool> show(BuildContext context) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SourceSwitchSheet(),
    );
    return changed == true;
  }

  @override
  State<SourceSwitchSheet> createState() => _SourceSwitchSheetState();
}

class _SourceSwitchSheetState extends State<SourceSwitchSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _keyword = '';

  /// false=单列列表 / true=双排网格（默认双排，与参考截图一致）
  bool _gridMode = true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _selectSource(SourceBean source) {
    ApiConfig.instance.setHomeSource(source);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.72;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部拖拽指示条
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 搜索图标（点击展开成输入条，失焦自动缩回）+ 单列/双排切换
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Row(
                  children: [
                    _ExpandableSearchField(
                      controller: _searchController,
                      keyword: _keyword,
                      onChanged: (v) => setState(() => _keyword = v.trim()),
                    ),
                    const SizedBox(width: 8),
                    // 单列/双排切换按钮
                    GestureDetector(
                      onTap: () => setState(() => _gridMode = !_gridMode),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _gridMode
                              ? Icons.view_list_outlined
                              : Icons.grid_view_outlined,
                          size: 17,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 源列表
              Flexible(
                child: Obx(() {
                  final all = ApiConfig.instance.sourceBeanList.value;
                  final selectedKey =
                      ApiConfig.instance.homeSourceBean.value?.key;
                  final list = _keyword.isEmpty
                      ? all
                      : all
                          .where((s) => s.name
                              .toLowerCase()
                              .contains(_keyword.toLowerCase()))
                          .toList();
                  if (list.isEmpty) {
                    return Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Center(
                        child: Text(
                          '未找到匹配的源',
                          style: TextStyle(color: AppTheme.textTertiary),
                        ),
                      ),
                    );
                  }
                  if (_gridMode) {
                    return GridView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 3.4,
                      ),
                      itemCount: list.length,
                      itemBuilder: (context, index) {
                        final source = list[index];
                        return _SourceTile(
                          name: source.name,
                          selected: source.key == selectedKey,
                          onTap: () => _selectSource(source),
                        );
                      },
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final source = list[index];
                      return _SourceRow(
                        name: source.name,
                        selected: source.key == selectedKey,
                        onTap: () => _selectSource(source),
                      );
                    },
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单列模式：一行一个源，圆圈 + 名称
class _SourceRow extends StatelessWidget {
  final String name;
  final bool selected;
  final VoidCallback onTap;

  const _SourceRow({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.accentColor.withValues(alpha: 0.12)
                : AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? AppTheme.accentColor.withValues(alpha: 0.4)
                  : AppTheme.borderLight,
              width: selected ? 1 : 0.5,
            ),
          ),
          child: Row(
            children: [
              // 猫爪风格源图标
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: selected
                      ? AppTheme.accentColor
                      : AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.pets,
                  size: 15,
                  color: selected ? Colors.white : AppTheme.textTertiary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    color: selected
                        ? AppTheme.textPrimary
                        : AppTheme.textSecondary,
                    fontSize: 14,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 可伸缩搜索框：初始只显示搜索图标，点击展开成输入条，失焦自动缩回
class _ExpandableSearchField extends StatefulWidget {
  final TextEditingController controller;
  final String keyword;
  final ValueChanged<String> onChanged;

  const _ExpandableSearchField({
    required this.controller,
    required this.keyword,
    required this.onChanged,
  });

  @override
  State<_ExpandableSearchField> createState() => _ExpandableSearchFieldState();
}

class _ExpandableSearchFieldState extends State<_ExpandableSearchField> {
  bool _expanded = false;
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.of(context).size.width;
    final expandedW = (maxW * 0.55).clamp(150.0, 240.0);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: _expanded ? expandedW : 34,
      height: 34,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2E),
        borderRadius: BorderRadius.circular(17),
      ),
      child: _expanded
          ? Row(
              children: [
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focus,
                    autofocus: true,
                    style: TextStyle(
                        color: AppTheme.textPrimary, fontSize: 13),
                    onChanged: widget.onChanged,
                    // 点输入框外部 → 自动缩回
                    onTapOutside: (_) {
                      if (_expanded) {
                        setState(() => _expanded = false);
                        _focus.unfocus();
                      }
                    },
                    decoration: InputDecoration(
                      hintText: '搜索源...',
                      hintStyle: TextStyle(
                          color: AppTheme.textTertiary, fontSize: 13),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                if (widget.keyword.isNotEmpty)
                  GestureDetector(
                    onTap: () {
                      widget.controller.clear();
                      widget.onChanged('');
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close,
                          color: AppTheme.textTertiary, size: 14),
                    ),
                  ),
                const SizedBox(width: 8),
              ],
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => _expanded = true);
                _focus.requestFocus();
              },
              child:
                  Icon(Icons.search, color: AppTheme.textSecondary, size: 16),
            ),
    );
  }
}

/// 双排模式：网格卡片，圆圈 + 名称
class _SourceTile extends StatelessWidget {
  final String name;
  final bool selected;
  final VoidCallback onTap;

  const _SourceTile({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? AppTheme.accentColor.withValues(alpha: 0.4)
                : AppTheme.borderLight,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              size: 16,
              color: selected
                  ? AppTheme.accentColor
                  : AppTheme.textTertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: selected
                      ? AppTheme.textPrimary
                      : AppTheme.textSecondary,
                  fontSize: 13,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
