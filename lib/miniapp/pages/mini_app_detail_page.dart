import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/live_models.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/services/main_tab_controller.dart';
import 'package:tvbox/services/network_manager.dart';
import 'package:tvbox/services/spider_service.dart';
import 'package:tvbox/widgets/glass.dart';
import 'package:tvbox/miniapp/models/mini_app.dart';
import 'package:tvbox/miniapp/services/mini_app_service.dart';

/// 「程序」详情页：影视（CMS 浏览 → 现有详情/播放链路）+ 频道（直播）。
class MiniAppDetailPage extends StatefulWidget {
  final String appId;
  const MiniAppDetailPage({super.key, required this.appId});

  @override
  State<MiniAppDetailPage> createState() => _MiniAppDetailPageState();
}

class _MiniAppDetailPageState extends State<MiniAppDetailPage>
    with SingleTickerProviderStateMixin {
  MiniApp get _app =>
      MiniAppService.instance.apps.firstWhere((a) => a.id == widget.appId);

  late TabController _tab;
  final _videoCtrl = _MiniAppVideoController();

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(() {
      if (!_tab.indexIsChanging && _tab.index == 0) {
        _videoCtrl.initLoad(_app);
      }
    });
    _videoCtrl.initLoad(_app);
  }

  @override
  void dispose() {
    _tab.dispose();
    _videoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    final parsed = app.parsed;
    final hasVideo =
        parsed.cmsSites.isNotEmpty || parsed.spiderSites.isNotEmpty;
    final hasLive = parsed.liveGroups.isNotEmpty;

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
                    const SizedBox(width: 40),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.spacingSM),

              // ── Tab 切换 ───────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundSecondary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: TabBar(
                    controller: _tab,
                    indicator: BoxDecoration(
                      color: AppTheme.accentColor,
                      borderRadius: BorderRadius.circular(17),
                    ),
                    indicatorSize: TabBarIndicatorSize.tab,
                    dividerColor: Colors.transparent,
                    labelColor: Colors.white,
                    unselectedLabelColor: AppTheme.textSecondary,
                    labelStyle: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                    tabs: [
                      Tab(text: hasVideo ? '影视' : '影视(无)'),
                      Tab(text: hasLive ? '频道' : '频道(无)'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppTheme.spacingSM),

              Expanded(
                child: TabBarView(
                  controller: _tab,
                  children: [
                    hasVideo
                        ? _MiniAppVideoView(controller: _videoCtrl)
                        : _EmptyHint(
                            text: parsed.hasInlineSpider
                                ? '该配置的影视源是内嵌 JS 脚本（非 URL），暂不支持执行'
                                : '该配置没有可用的影视源'),
                    hasLive
                        ? _MiniAppLiveView(app: app)
                        : _EmptyHint(text: '该配置没有直播频道'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 影视浏览
// ══════════════════════════════════════════════════════════════

/// CMS / Spider 浏览状态：分类 + 列表 + 搜索 + 分页
class _MiniAppVideoController extends GetxController {
  MiniApp? _app;

  /// 当前生效的影视源（优先 CMS，无 CMS 时用 Spider）
  MiniAppCmsSite? _cmsSite;
  MiniAppSpiderSite? _spiderSite;

  bool get _isSpider => _cmsSite == null && _spiderSite != null;
  String get _sourceKey =>
      _isSpider ? '${_app!.id}_s0' : '${_app!.id}_0';

  final loading = false.obs;
  final error = RxnString();
  final classes = <({String id, String name})>[].obs;
  final items = <Video>[].obs;
  final searching = false.obs;

  String _activeClass = '';
  int _page = 1;
  bool _hasMore = true;
  int _loadToken = 0;

  void initLoad(MiniApp app) {
    if (_app?.id == app.id) return;
    _app = app;
    final parsed = app.parsed;
    _cmsSite = parsed.cmsSites.isNotEmpty ? parsed.cmsSites.first : null;
    _spiderSite =
        (_cmsSite == null && parsed.spiderSites.isNotEmpty)
            ? parsed.spiderSites.first
            : null;
    _loadHome();
  }

  Future<void> _loadHome() async {
    items.clear();
    error.value = null;
    await _fetch(page: 1, tid: '');
  }

  Future<void> _fetch({required int page, required String tid}) async {
    final token = ++_loadToken;
    loading.value = true;
    try {
      final Map<String, dynamic>? decoded;
      if (_isSpider) {
        // 脚本源 → SpiderService 统一路由：
        //   .py 走 CPython（自动下载+注册），.js/drpy2 按需载入 Node 引擎，
        //   key 也由引擎 /config 决定 —— 不再用自造的 app_xxx_s0 去请求。
        final site = _spiderSite!;
        if (page == 1 && tid.isEmpty) {
          decoded = await SpiderService.instance
              .getHomeContent(_sourceKey, 3, site.api, ext: site.ext);
        } else {
          decoded = await SpiderService.instance.getCategoryContent(
              _sourceKey, 3, site.api, tid,
              page: page, ext: site.ext);
        }
      } else {
        final url =
            '${_cmsSite!.api}?ac=list&pg=$page${tid.isNotEmpty ? '&t=$tid' : ''}';
        final body = await NetworkManager.instance.getString(url);
        decoded = jsonDecode(body) as Map<String, dynamic>?;
      }
      if (token != _loadToken) return;
      if (decoded == null) throw Exception('响应不是 JSON 对象');

      // 分类（仅首页/第一页解析一次）
      final classRaw = decoded['class'];
      if (page == 1 && classRaw is List && classes.isEmpty) {
        final list = <({String id, String name})>[];
        for (final c in classRaw) {
          if (c is! Map) continue;
          final id = (c['type_id'] ?? '').toString();
          final name = (c['type_name'] ?? '').toString();
          if (id.isNotEmpty && name.isNotEmpty) {
            list.add((id: id, name: name));
          }
        }
        if (list.isNotEmpty) classes.assignAll(list);
      }

      final listRaw = decoded['list'];
      final videos = <Video>[];
      if (listRaw is List) {
        for (final v in listRaw) {
          if (v is! Map) continue;
          final vodId = (v['vod_id'] ?? '').toString();
          if (vodId.isEmpty) continue;
          videos.add(Video.fromJson(Map<String, dynamic>.from(v))
            ..sourceKey = _sourceKey);
        }
      }
      if (page == 1) {
        items.assignAll(videos);
      } else {
        items.addAll(videos);
      }
      _hasMore = videos.isNotEmpty;
      _page = page;
    } catch (e) {
      if (token == _loadToken) {
        error.value = '加载失败: $e';
      }
    } finally {
      if (token == _loadToken) loading.value = false;
    }
  }

  Future<void> selectClass(String id) async {
    if (_activeClass == id) return;
    _activeClass = id;
    classes.refresh();
    items.clear();
    await _fetch(page: 1, tid: id);
  }

  Future<void> search(String keyword) async {
    final kw = keyword.trim();
    _activeClass = '';
    items.clear();
    classes.refresh();
    searching.value = true;
    final token = ++_loadToken;
    try {
      if (kw.isEmpty) {
        await _fetch(page: 1, tid: '');
      } else {
        final Map<String, dynamic>? decoded;
        if (_isSpider) {
          // 脚本源 → 原子 init + search（路由同 _fetch）
          final site = _spiderSite!;
          decoded = await SpiderService.instance.searchWithSpider(
            spiderKey: _sourceKey,
            spiderType: 3,
            api: site.api,
            keyword: kw,
            ext: site.ext,
          );
        } else {
          final url =
              '${_cmsSite!.api}?ac=detail&wd=${Uri.encodeComponent(kw)}';
          final body = await NetworkManager.instance.getString(url);
          decoded = jsonDecode(body) as Map<String, dynamic>?;
        }
        if (token != _loadToken) return;
        final videos = <Video>[];
        final listRaw = decoded?['list'];
        if (listRaw is List) {
          for (final v in listRaw) {
            if (v is! Map) continue;
            final vodId = (v['vod_id'] ?? '').toString();
            if (vodId.isEmpty) continue;
            videos.add(Video.fromJson(Map<String, dynamic>.from(v))
              ..sourceKey = _sourceKey);
          }
        }
        items.assignAll(videos);
        _hasMore = false;
        _page = 1;
      }
    } catch (e) {
      error.value = '搜索失败: $e';
    } finally {
      if (token == _loadToken) searching.value = false;
    }
  }

  void loadMore() {
    if (loading.value || searching.value || !_hasMore) return;
    _fetch(page: _page + 1, tid: _activeClass);
  }
}

class _MiniAppVideoView extends StatefulWidget {
  final _MiniAppVideoController controller;
  const _MiniAppVideoView({required this.controller});

  @override
  State<_MiniAppVideoView> createState() => _MiniAppVideoViewState();
}

class _MiniAppVideoViewState extends State<_MiniAppVideoView> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Obx(() {
      final classes = controller.classes;
      return Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.backgroundSecondary,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(Icons.search, size: 16, color: AppTheme.textSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      textInputAction: TextInputAction.search,
                      style: TextStyle(
                          color: AppTheme.textPrimary, fontSize: 14),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '搜索影视',
                        hintStyle: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 14),
                      ),
                      onSubmitted: (v) => controller.search(v),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.clear,
                        size: 16, color: AppTheme.textSecondary),
                    onPressed: () {
                      _searchCtrl.clear();
                      controller.search('');
                    },
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          // 分类 chips
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _ClassChip(
                  label: '全部',
                  active: controller._activeClass.isEmpty,
                  onTap: () => controller.selectClass(''),
                ),
                for (final c in classes)
                  _ClassChip(
                    label: c.name,
                    active: controller._activeClass == c.id,
                    onTap: () => controller.selectClass(c.id),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // 结果
          Expanded(
            child: controller.loading.value && controller.items.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2.5))
                : controller.error.value != null && controller.items.isEmpty
                    ? _EmptyHint(text: controller.error.value ?? '加载失败')
                    : controller.items.isEmpty
                        ? const _EmptyHint(text: '暂无内容，试试搜索')
                        : NotificationListener<ScrollNotification>(
                            onNotification: (n) {
                              if (n.metrics.pixels >
                                  n.metrics.maxScrollExtent - 300) {
                                controller.loadMore();
                              }
                              return false;
                            },
                            child: GridView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                  16, 4, 16, 110),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 140,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 0.62,
                              ),
                              itemCount: controller.items.length,
                              itemBuilder: (context, index) {
                                final v = controller.items[index];
                                return _VideoCard(
                                  video: v,
                                  onTap: () => Get.toNamed('/detail',
                                      arguments: v),
                                );
                              },
                            ),
                          ),
          ),
        ],
      );
    });
  }
}

class _ClassChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ClassChip(
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

class _VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onTap;
  const _VideoCard({required this.video, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: video.pic.isEmpty
                  ? Container(
                      color: AppTheme.backgroundSecondary,
                      alignment: Alignment.center,
                      child: Icon(Icons.movie_outlined,
                          size: 30, color: AppTheme.textSecondary),
                    )
                  : Image.network(
                      video.pic,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: AppTheme.backgroundSecondary,
                        alignment: Alignment.center,
                        child: Icon(Icons.movie_outlined,
                            size: 30, color: AppTheme.textSecondary),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            video.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500),
          ),
          if (video.note.isNotEmpty)
            Text(
              video.note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(color: AppTheme.textSecondary, fontSize: 11),
            ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 频道浏览
// ══════════════════════════════════════════════════════════════

class _MiniAppLiveView extends StatelessWidget {
  final MiniApp app;
  const _MiniAppLiveView({required this.app});

  @override
  Widget build(BuildContext context) {
    final groups = app.parsed.liveGroups;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 110),
      children: [
        for (final group in groups) _LiveGroupTile(group: group, app: app),
      ],
    );
  }
}

class _LiveGroupTile extends StatefulWidget {
  final LiveGroup group;
  final MiniApp app;
  const _LiveGroupTile({required this.group, required this.app});

  @override
  State<_LiveGroupTile> createState() => _LiveGroupTileState();
}

class _LiveGroupTileState extends State<_LiveGroupTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final channels = widget.group.channels;
    return GlassPanel(
      radius: 14,
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.group.name}（${channels.length}）',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: AppTheme.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            ...channels.map((ch) => _LiveChannelTile(
                  channel: ch,
                  app: widget.app,
                )),
        ],
      ),
    );
  }
}

class _LiveChannelTile extends StatelessWidget {
  final LiveChannel channel;
  final MiniApp app;
  const _LiveChannelTile({required this.channel, required this.app});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        // 先 pop 回根（本页是从 tab 页 push 进来的），再切直播 tab：
        // 直播页会展示该程序的频道列表并自动加载
        Get.back();
        await MiniAppService.instance.playLives(app);
        MainTabController.instance.select(4); // 直播 tab 索引（NavFeature.live）
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 14, 10),
        child: Row(
          children: [
            Icon(Icons.live_tv_outlined,
                size: 18, color: AppTheme.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: AppTheme.textPrimary, fontSize: 14),
              ),
            ),
            Icon(Icons.play_circle_outline,
                size: 16, color: AppTheme.accentColor),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 空态
// ══════════════════════════════════════════════════════════════

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
              style:
                  TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
