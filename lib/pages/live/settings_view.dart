import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/theme.dart';
import 'blocked_categories_page.dart';
import '../../services/live_service.dart';
import '../../services/xtream_service.dart';
import '../../widgets/app_toast.dart';

/// 设置 → 直播：直播源管理 + 全局 EPG + 屏蔽分类
class LiveSettingsPage extends StatefulWidget {
  const LiveSettingsPage({super.key});

  @override
  State<LiveSettingsPage> createState() => _LiveSettingsPageState();
}

class _LiveSettingsPageState extends State<LiveSettingsPage> {
  final _epgCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _restoreEpg();
  }

  Future<void> _restoreEpg() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('epg_url') ?? '';
      if (mounted) _epgCtrl.text = saved;
    } catch (e) {
      /* ignore */
    }
  }

  @override
  void dispose() {
    _epgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 不透明底，避免路由切换时与下层设置页叠影
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new,
            color: AppTheme.accentColor,
            size: 20,
          ),
          onPressed: () => Get.back(),
        ),
        title: Text(
          '直播设置',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontTitle3,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Row(
            children: [
              Text(
                '直播源管理',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '自动排序',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.sort_by_alpha_rounded,
                  size: 20,
                  color: AppTheme.textSecondary,
                ),
                onPressed: () async {
                  final svc = LiveService.instance;
                  final multi = svc.sources.length >= 2;
                  await svc.autoSortSources();
                  if (!mounted) return;
                  AppToast.message(
                    multi ? '已按名称自动排序' : '当前只有一个直播源，无需排序',
                  );
                  setState(() {});
                },
              ),
            ],
          ),
          const SizedBox(height: 2),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.backgroundSecondary,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Obx(() {
              // 依赖 sourcesTick，改名/增删后强制重建
              final _ = LiveService.instance.sourcesTick.value;
              final svc = LiveService.instance;
              final srcs = svc.sources.toList();
              // 「添加直播源」按钮必须**始终**可见：空列表时也要能直接加，
              // 否则全新安装要先到直播页加一个源、设置页才冒出按钮（用户实测困惑）。
              return Column(
                children: [
                  if (srcs.isEmpty)
                    const _EmptyRow()
                  else
                    // 源列表可拖动排序；「添加直播源」放在 ReorderableListView
                    // 之外，因此不参与排序、也不可拖。
                    ReorderableListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      onReorder: svc.reorderSource,
                      children: [
                        for (var i = 0; i < srcs.length; i++)
                          _sourceTile(
                            i,
                            srcs[i],
                            key: ValueKey(
                              '$i|${srcs[i].name}|${svc.getSourceUrl(i) ?? ''}',
                            ),
                          ),
                      ],
                    ),
                  _addTile(),
                ],
              );
            }),
          ),
          SizedBox(height: 24),
          Text(
            '全局 EPG 地址',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.backgroundSecondary,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '直播源未自带 EPG 时使用，如 https://example.com/epg.xml.gz',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontFootnote,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _epgCtrl,
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontSubhead,
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: AppTheme.backgroundTertiary,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          hintText: 'https://...',
                          hintStyle: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontSubhead,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 10),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accentColor,
                        // 强调色上必须按亮度选前景：写死黑色时，
                        // ink 强调色 #3A3A3A 上的黑字对比只有约 1.3:1。
                        foregroundColor:
                            AppTheme.accentColor.computeLuminance() > 0.5
                                ? Colors.black
                                : Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                      ),
                      onPressed: () async {
                        final v = _epgCtrl.text.trim();
                        try {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setString('epg_url', v);
                        } catch (e) {
                          /* ignore */
                        }
                        AppToast.message(
                          v.isEmpty ? '已清空 EPG 地址' : 'EPG 地址已保存',
                        );
                      },
                      child: const Text(
                        '保存',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: 24),
          Text(
            '屏蔽分类管理',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          // 改为跳转独立管理页（可手动输入分类名，也能从当前源里挑）
          Container(
            decoration: BoxDecoration(
              color: AppTheme.backgroundSecondary,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Obx(() {
              final blocked = LiveService.instance.blockedGroups;
              return ListTile(
                leading: Icon(
                  Icons.block,
                  size: 20,
                  color: AppTheme.textSecondary,
                ),
                title: Text(
                  '屏蔽分类',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontBody,
                  ),
                ),
                subtitle: Text(
                  blocked.isEmpty
                      ? '屏蔽后隐藏对应分类的频道'
                      : '已屏蔽 ${blocked.length} 个：${blocked.take(3).join("、")}'
                            '${blocked.length > 3 ? "…" : ""}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppTheme.textTertiary,
                ),
                onTap: () => Get.to(() => const BlockedCategoriesPage()),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _sourceTile(int index, LiveSource src, {required Key key}) {
    final svc = LiveService.instance;
    final loaded = src.loaded;
    final sourceUrl = svc.getSourceUrl(index);
    final canEdit = sourceUrl != null && sourceUrl.isNotEmpty;
    // Xtream 源加标记，并展示到期时间（如「Xtream · 到期 2026-01-01」）
    final isXtream = svc.isXtreamSource(index);
    final expiry = svc.xtreamExpiryText(index);
    final isMaiyou = svc.isMaiyouSource(index);
    final sub = isXtream
        ? 'Xtream${expiry == null ? ' · ${src.statusText()}' : ' · $expiry'}'
        : isMaiyou
            ? '麦优订阅 · ${src.statusText()}'
            : src.statusText();
    return ListTile(
      key: key,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      // 左侧：拖动手柄 + 图标。手柄套 ReorderableDragStartListener，
      // 只有按住手柄才进入拖动，点击整行仍是「切换加载该源」。
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                Icons.drag_indicator,
                color: AppTheme.textTertiary,
                size: 20,
              ),
            ),
          ),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: loaded
                  ? AppTheme.accentColor.withValues(alpha: 0.18)
                  : AppTheme.backgroundTertiary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.live_tv,
              color: loaded ? AppTheme.accentColor : AppTheme.textTertiary,
              size: 20,
            ),
          ),
        ],
      ),
      title: Text(
        src.name,
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: AppTheme.fontHeadline,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        sub,
        style: TextStyle(
          color: loaded ? AppTheme.textSecondary : AppTheme.textTertiary,
          fontSize: AppTheme.fontFootnote,
        ),
      ),
      trailing: PopupMenuButton<String>(
        // 不写死底色：原来固定 #2A2A2E，而 M3 菜单文字取
        // `textTheme.labelLarge`（浅色主题下是深色）→ 深底压深字不可读。
        icon: Icon(Icons.more_vert, color: AppTheme.textSecondary),
        onSelected: (v) async {
          if (v == 'refresh') {
            await svc.reloadSource(index);
            final err = svc.error.value;
            if (mounted) {
              AppToast.message(err == null ? '已刷新 ${src.name}' : '刷新失败：$err');
            }
            setState(() {});
          } else if (v == 'edit') {
            final result = await showDialog<(String, String)>(
              context: context,
              builder: (ctx) {
                final nameCtrl = TextEditingController(text: src.name);
                final ctrl = TextEditingController(text: sourceUrl ?? '');
                return AlertDialog(
                  backgroundColor: AppTheme.backgroundSecondary,
                  title: Text(
                    '编辑直播源',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontHeadline,
                    ),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: nameCtrl,
                        style: TextStyle(color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          hintText: '源名称',
                          hintStyle: TextStyle(color: AppTheme.textTertiary),
                        ),
                      ),
                      SizedBox(height: 10),
                      TextField(
                        controller: ctrl,
                        style: TextStyle(color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          hintText: 'm3u / txt 地址',
                          hintStyle: TextStyle(color: AppTheme.textTertiary),
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, (
                        nameCtrl.text.trim(),
                        ctrl.text.trim(),
                      )),
                      child: const Text('保存'),
                    ),
                  ],
                );
              },
            );
            if (result != null &&
                (result.$1.isNotEmpty || result.$2.isNotEmpty)) {
              await svc.updateSourceMeta(
                index,
                name: result.$1,
                url: result.$2,
              );
              if (mounted) {
                AppToast.message(
                  svc.error.value == null
                      ? '已更新 ${result.$1.isEmpty ? src.name : result.$1}'
                      : '更新失败：${svc.error.value}',
                  duration: const Duration(seconds: 3),
                );
              }
              setState(() {});
            }
          } else if (v == 'delete') {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: AppTheme.backgroundSecondary,
                title: Text(
                  '删除直播源',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontHeadline,
                  ),
                ),
                content: Text(
                  '确定删除「${src.name}」吗？',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontSubhead,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text(
                      '删除',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ],
              ),
            );
            if (ok == true) {
              await svc.removeSource(index);
              if (mounted) {
                AppToast.message('已删除 ${src.name}');
              }
              setState(() {});
            }
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'refresh',
            child: Text('立即刷新', style: TextStyle(color: AppTheme.textPrimary)),
          ),
          if (canEdit)
            PopupMenuItem(
              value: 'edit',
              child: Text(
                '编辑直播源',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
            ),
          const PopupMenuItem(
            value: 'delete',
            child: Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Widget _addTile() {
    return ListTile(
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppTheme.accentColor.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(Icons.add, color: AppTheme.accentColor, size: 20),
      ),
      title: Text(
        '添加直播源',
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: AppTheme.fontHeadline,
        ),
      ),
      trailing: Icon(Icons.chevron_right, color: AppTheme.textTertiary),
      onTap: () async {
        final result = await showDialog<
            ({String name, String url, bool xtream, bool maiyou})>(
          context: context,
          builder: (ctx) => const _AddLiveSourceDialog(),
        );
        if (result != null && result.url.isNotEmpty) {
          await LiveService.instance.addSource(
            result.url,
            name: result.name.isEmpty ? null : result.name,
            xtream: result.xtream,
            maiyou: result.maiyou,
          );
          if (mounted) {
            final err = LiveService.instance.error.value;
            final count = LiveService.instance.channels.length;
            final srcCount = LiveService.instance.sources.length;
            AppToast.message(
              err == null ? '已添加第 $srcCount 个直播源，共 $count 个频道' : '添加失败：$err',
              duration: const Duration(seconds: 3),
            );
          }
          setState(() {});
        }
      },
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          '暂无直播源，可添加 m3u 地址',
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: AppTheme.fontSubhead,
          ),
        ),
      ),
    );
  }
}

/// 「添加直播源」对话框：支持 m3u / txt 地址、Xtream 账号、麦优订阅三种模式。
class _AddLiveSourceDialog extends StatefulWidget {
  const _AddLiveSourceDialog();

  @override
  State<_AddLiveSourceDialog> createState() => _AddLiveSourceDialogState();
}

class _AddLiveSourceDialogState extends State<_AddLiveSourceDialog> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  /// 0=m3u/txt，1=Xtream 账号，2=麦优订阅
  int _mode = 0;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _hostCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  InputDecoration _dec(String hint) => InputDecoration(
    filled: true,
    fillColor: AppTheme.backgroundTertiary,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    hintText: hint,
    hintStyle: TextStyle(
      color: AppTheme.textTertiary,
      fontSize: AppTheme.fontSubhead,
    ),
  );

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (_mode == 1) {
      // 服务器地址可填 host:port，也可直接粘完整 get.php 链接
      final acc = XtreamService.instance.parseAccount(_hostCtrl.text);
      if (acc == null || acc.base.isEmpty) {
        AppToast.message('请输入有效的 host:port 或完整账号链接');
        return;
      }
      final user =
          _userCtrl.text.trim().isNotEmpty ? _userCtrl.text.trim() : acc.user;
      final pass =
          _passCtrl.text.trim().isNotEmpty ? _passCtrl.text.trim() : acc.pass;
      if (user.isEmpty || pass.isEmpty) {
        AppToast.message('请填写用户名和密码');
        return;
      }
      final url = XtreamService.instance.buildAccountUrl(acc.base, user, pass);
      Navigator.pop(context,
          (name: name, url: url, xtream: true, maiyou: false));
    } else if (_mode == 2) {
      final url = _urlCtrl.text.trim();
      if (url.isEmpty) {
        AppToast.message('请输入麦优订阅地址（json.txt 链接）');
        return;
      }
      Navigator.pop(context,
          (name: name, url: url, xtream: false, maiyou: true));
    } else {
      final url = _urlCtrl.text.trim();
      if (url.isEmpty) {
        AppToast.message('请输入 m3u / txt 地址');
        return;
      }
      Navigator.pop(context,
          (name: name, url: url, xtream: false, maiyou: false));
    }
  }

  Widget _modeChip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      labelStyle: TextStyle(
        color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
        fontSize: AppTheme.fontFootnote,
      ),
      selectedColor: AppTheme.accentColor.withValues(alpha: 0.25),
      backgroundColor: AppTheme.backgroundTertiary,
      side: BorderSide.none,
      showCheckmark: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final fieldStyle = TextStyle(
      color: AppTheme.textPrimary,
      fontSize: AppTheme.fontSubhead,
    );
    return AlertDialog(
      backgroundColor: AppTheme.backgroundSecondary,
      title: Text(
        '添加直播源',
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: AppTheme.fontHeadline,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _modeChip(
                  'm3u / txt 地址',
                  _mode == 0,
                  () => setState(() => _mode = 0),
                ),
                const SizedBox(width: 8),
                _modeChip(
                  'Xtream 账号',
                  _mode == 1,
                  () => setState(() => _mode = 1),
                ),
                const SizedBox(width: 8),
                _modeChip(
                  '麦优订阅',
                  _mode == 2,
                  () => setState(() => _mode = 2),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              style: fieldStyle,
              decoration: _dec('源名称（可选）'),
            ),
            const SizedBox(height: 10),
            if (_mode == 1) ...[
              TextField(
                controller: _hostCtrl,
                keyboardType: TextInputType.url,
                style: fieldStyle,
                decoration: _dec('服务器地址 host:port 或完整 get.php 链接'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _userCtrl,
                style: fieldStyle,
                decoration: _dec('用户名'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _passCtrl,
                style: fieldStyle,
                decoration: _dec('密码'),
              ),
            ] else
              TextField(
                controller: _urlCtrl,
                keyboardType: TextInputType.url,
                style: fieldStyle,
                decoration: _dec(
                  _mode == 2
                      ? '麦优订阅地址（如 http://api.maiyoux.com:81/mf/json.txt）'
                      : 'm3u / txt 地址',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }
}
