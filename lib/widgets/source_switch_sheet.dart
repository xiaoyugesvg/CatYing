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
              // 搜索框 + 单列/双排切换
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.search,
                                color: AppTheme.textTertiary, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 14),
                                onChanged: (v) =>
                                    setState(() => _keyword = v.trim()),
                                decoration: const InputDecoration(
                                  hintText: '搜索源...',
                                  hintStyle: TextStyle(
                                      color: AppTheme.textTertiary,
                                      fontSize: 14),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding:
                                      EdgeInsets.symmetric(vertical: 10),
                                ),
                              ),
                            ),
                            if (_keyword.isNotEmpty)
                              GestureDetector(
                                onTap: () {
                                  _searchController.clear();
                                  setState(() => _keyword = '');
                                },
                                child: const Icon(Icons.close,
                                    color: AppTheme.textTertiary, size: 16),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // 单列/双排切换按钮
                    GestureDetector(
                      onTap: () => setState(() => _gridMode = !_gridMode),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _gridMode
                              ? Icons.view_list_outlined
                              : Icons.grid_view_outlined,
                          size: 20,
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
                    return const Padding(
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
              Icon(
                selected
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected
                    ? AppTheme.accentColor
                    : AppTheme.textTertiary,
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
