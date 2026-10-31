import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/live_models.dart';
import 'package:tvbox/pages/live/controller.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/live_service.dart';
import 'package:tvbox/services/main_tab_controller.dart';
import 'package:tvbox/services/network_manager.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/miniapp/models/mini_app.dart';
import 'package:tvbox/miniapp/services/mini_app_service.dart';

/// 麦优直播独立应用页：分类浏览 + 频道网格 + 播放（复用直播页播放链路）。
///
/// 导入/打开/管理均为独立页面形态：
/// - 顶栏：返回、应用名、刷新、管理（编辑订阅地址 / 删除应用）
/// - 分类 chips：拉 json.txt 的 pingtai 分类
/// - 频道网格：拉所选分类文件（jsonxxx.txt）的 zhubo 列表
/// - 点频道：把该分类频道交给直播页（临时展示），切直播 tab 播放目标频道
class MiniAppMaiyouPage extends StatefulWidget {
  final String appId;
  const MiniAppMaiyouPage({super.key, required this.appId});

  @override
  State<MiniAppMaiyouPage> createState() => _MiniAppMaiyouPageState();
}

class _MiniAppMaiyouPageState extends State<MiniAppMaiyouPage> {
  /// 找到当前小程序。
  ///
  /// ⚠️ 本页第 `_confirmDelete` 里就有 `MiniAppService.instance.remove(_app)` ——
  ///    删完自己之后只要页面再 build 一次，原来那个不带 `orElse` 的
  ///    `firstWhere` 就会抛 `StateError: No element`，把「删除成功」变成崩溃。
  ///    兜一个「已不存在」占位即可。
  MiniApp get _app => MiniAppService.instance.apps.firstWhere(
        (a) => a.id == widget.appId,
        orElse: () => MiniApp(
          id: widget.appId,
          name: '程序已不存在',
          type: '',
          source: '',
          rawJson: '{}',
          createdAt: 0,
        ),
      );

  late final _MaiyouController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = _MaiyouController(app: _app);
    _ctrl.loadClasses();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _showManage() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.edit_outlined,
                  size: 20, color: AppTheme.textPrimary),
              title: Text('编辑订阅地址',
                  style: TextStyle(
                      color: AppTheme.textPrimary, fontSize: 15)),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  size: 20, color: Colors.redAccent),
              title: Text('删除应用',
                  style: TextStyle(color: Colors.redAccent, fontSize: 15)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == 'edit') {
      await _editUrl();
    } else if (action == 'delete') {
      await _deleteApp();
    }
  }

  Future<void> _editUrl() async {
    final ctrl = TextEditingController(text: _app.parsed.maiyouUrl);
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('编辑订阅地址',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'https://…/json.txt',
            hintStyle: TextStyle(color: AppTheme.textSecondary),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppTheme.borderMedium),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Get.back(result: true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final url = ctrl.text.trim();
    if (url.isEmpty) {
      AppToast.message('订阅地址不能为空');
      return;
    }
    final r = await MiniAppService.instance.updateMaiyouUrl(_app, url);
    if (r.ok) {
      AppToast.message('已保存，正在刷新');
      _ctrl.refreshAll();
    } else {
      AppToast.message(r.error ?? '保存失败');
    }
  }

  Future<void> _deleteApp() async {
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('删除应用',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: Text('删除「${_app.name}」？',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Get.back(result: true),
              child: Text('删除', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok == true) {
      await MiniAppService.instance.remove(_app);
      Get.back();
      AppToast.message('已删除');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        color: Colors.transparent,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // ── 顶栏 ──────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppTheme.spacingSM, AppTheme.spacingSM, 0, 0),
                child: Row(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => Get.back(),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(Icons.arrow_back_ios_new,
                            size: 18, color: AppTheme.textPrimary),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.refresh,
                          size: 20, color: AppTheme.textPrimary),
                      onPressed: _ctrl.refreshAll,
                    ),
                    IconButton(
                      tooltip: '管理',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.more_horiz,
                          size: 22, color: AppTheme.textPrimary),
                      onPressed: _showManage,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.spacingSM),

              // ── 分类 chips ─────────────────────────────────────
              Obx(() {
                final classes = _ctrl.classes;
                if (classes.isEmpty) return const SizedBox(height: 34);
                return SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      for (var i = 0; i < classes.length; i++)
                        _CatChip(
                          label: classes[i].name,
                          active: i == _ctrl.activeCat,
                          onTap: () => _ctrl.selectCat(i),
                        ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 4),

              // ── 频道网格 ───────────────────────────────────────
              Expanded(
                child: Obx(() {
                  if (_ctrl.loading.value && _ctrl.items.isEmpty) {
                    return const Center(
                        child: CircularProgressIndicator(strokeWidth: 2.5));
                  }
                  if (_ctrl.error.value != null && _ctrl.items.isEmpty) {
                    return _EmptyHint(text: _ctrl.error.value!);
                  }
                  if (_ctrl.items.isEmpty) {
                    return const _EmptyHint(text: '该分类暂无频道');
                  }
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 120,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.72,
                    ),
                    itemCount: _ctrl.items.length,
                    itemBuilder: (context, index) {
                      final ch = _ctrl.items[index];
                      return _ChannelCard(
                        channel: ch,
                        onTap: () => _ctrl.playChannel(index),
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

/// 麦优页面状态：分类 / 当前分类频道 / 刷新 / 播放接线
class _MaiyouController extends GetxController {
  final MiniApp app;
  _MaiyouController({required this.app});

  final loading = false.obs;
  final error = RxnString();

  /// pingtai 分类（name / file / img）
  final classes = <({String name, String file, String? img})>[].obs;
  final items = <LiveChannel>[].obs;
  int activeCat = 0;

  String get _subUrl => app.parsed.maiyouUrl;

  Future<void> refreshAll() async {
    activeCat = 0;
    items.clear();
    error.value = null;
    await loadClasses();
  }

  Future<void> loadClasses() async {
    final url = _subUrl;
    if (url.isEmpty) {
      error.value = '订阅地址为空，请在管理中编辑';
      return;
    }
    loading.value = true;
    try {
      final body = await NetworkManager.instance.getString(url);
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw Exception('分类索引不是 JSON 对象');
      final pingtai = decoded['pingtai'];
      if (pingtai is! List || pingtai.isEmpty) {
        throw Exception('分类索引里没有 pingtai 分类');
      }
      final list = <({String name, String file, String? img})>[];
      for (final c in pingtai) {
        if (c is! Map) continue;
        final name = (c['title'] ?? '').toString().trim();
        final file = (c['address'] ?? '').toString().trim();
        if (name.isEmpty || file.isEmpty) continue;
        list.add((name: name, file: file, img: c['xinimg']?.toString()));
      }
      if (list.isEmpty) throw Exception('没有可用的分类');
      classes.assignAll(list);
      activeCat = 0;
      await loadCategory(0);
    } catch (e) {
      AppLog.instance.log('[Maiyou] 分类加载失败: $e');
      error.value = '分类加载失败：$e';
    } finally {
      loading.value = false;
    }
  }

  Future<void> selectCat(int index) async {
    if (index < 0 || index >= classes.length) return;
    activeCat = index;
    classes.refresh();
    items.clear();
    await loadCategory(index);
  }

  Future<void> loadCategory(int index) async {
    if (index < 0 || index >= classes.length) return;
    final cat = classes[index];
    final uri = Uri.tryParse(_subUrl);
    if (uri == null) {
      error.value = '订阅地址无效';
      return;
    }
    loading.value = true;
    error.value = null;
    try {
      final catUri = uri.resolve(cat.file);
      final body = await NetworkManager.instance.getString(catUri.toString());
      final decoded = jsonDecode(body);
      final zhubo = decoded is Map ? decoded['zhubo'] : null;
      if (zhubo is! List) throw Exception('分类文件里没有 zhubo 频道');
      final list = <LiveChannel>[];
      for (final z in zhubo) {
        if (z is! Map) continue;
        final name = (z['title'] ?? '').toString().trim();
        final addr = (z['address'] ?? '').toString().trim();
        if (name.isEmpty || addr.isEmpty) continue;
        list.add(LiveChannel(
          name: name,
          urls: [addr],
          group: cat.name,
          logo: z['img']?.toString(),
        ));
      }
      items.assignAll(list);
      if (list.isEmpty) {
        error.value = '该分类暂无频道';
      }
    } catch (e) {
      AppLog.instance.log('[Maiyou] 频道加载失败: $e');
      error.value = '频道加载失败：$e';
    } finally {
      loading.value = false;
    }
  }

  /// 点频道：把当前分类频道临时交给直播页，切直播 tab 播放目标频道。
  Future<void> playChannel(int index) async {
    if (index < 0 || index >= items.length) return;
    final cat = classes.isNotEmpty && activeCat < classes.length
        ? classes[activeCat]
        : null;
    LiveService.instance
        .showEphemeralChannels([LiveGroup(name: cat?.name ?? '麦优', channels: items.toList())]);
    final ctrl = Get.isRegistered<LiveController>()
        ? Get.find<LiveController>()
        : null;
    if (ctrl != null) {
      ctrl.selectedGroupIndex.value = 0;
      ctrl.selectedChannelIndex.value = index;
      ctrl.update();
    }
    Get.back();
    MainTabController.instance.select(4); // 直播 tab
  }
}

class _CatChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _CatChip(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? AppTheme.accentColor : AppTheme.backgroundSecondary,
            borderRadius: BorderRadius.circular(17),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : AppTheme.textSecondary,
              fontSize: 13,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelCard extends StatelessWidget {
  final LiveChannel channel;
  final VoidCallback onTap;

  const _ChannelCard({required this.channel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final logo = channel.logo;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: logo == null || logo.isEmpty
                  ? Container(
                      color: AppTheme.backgroundSecondary,
                      alignment: Alignment.center,
                      child: Icon(Icons.live_tv_outlined,
                          size: 30, color: AppTheme.textSecondary),
                    )
                  : Image.network(
                      logo,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: AppTheme.backgroundSecondary,
                        alignment: Alignment.center,
                        child: Icon(Icons.live_tv_outlined,
                            size: 30, color: AppTheme.textSecondary),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            channel.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined,
              size: 48, color: AppTheme.textSecondary),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
