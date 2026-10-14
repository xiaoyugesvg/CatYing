import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/home_search_bar.dart';
import '../models/mini_app.dart';
import '../services/mini_app_service.dart';
import 'mini_app_detail_page.dart';
import 'mini_app_maiyou_page.dart';
import 'mini_app_market_page.dart';
import 'mini_app_web_page.dart';

/// 「程序」tab 主页：已安装小程序网格 + 导入入口。
///
/// 作为影视悬浮导航栏的独立分类页使用（NavFeature.apps / tabIndex 7），
/// 也是设置页「小程序」管理入口的目标页。
class MiniAppListPage extends StatefulWidget {
  const MiniAppListPage({super.key});

  @override
  State<MiniAppListPage> createState() => _MiniAppListPageState();
}

/// 程序列表排序方式
enum _AppSort {
  custom('自定义'),
  name('名称'),
  newest('最近添加');

  const _AppSort(this.label);
  final String label;
}

class _MiniAppListPageState extends State<MiniAppListPage> {
  MiniAppService get service => MiniAppService.instance;
  bool _busy = false;

  /// 视图：true = 网格 / false = 列表
  bool _gridMode = true;

  /// 排序（自定义 = 按存储顺序，可拖动调整）
  _AppSort _sort = _AppSort.custom;

  /// 顶栏搜索（输入框由 `HomeSearchBar` 自己持有展开态，这里只跟着它过滤）
  final _searchCtrl = TextEditingController();
  String _query = '';

  /// 顶部双 Tab（对齐参考图）：0 = 已安装 / 1 = 市场
  int _tab = 0;

  /// 市场 Tab 是否进过 —— 懒加载：没点过就不建 State、不发请求
  bool _marketVisited = false;

  /// 从「添加程序 → 小程序市场」导入时带进市场 Tab 的地址与已解析清单
  /// （带上清单是为了省掉一次重复下载）
  String? _pendingMarketUrl;
  List<MiniAppMarketEntry>? _pendingMarketList;

  @override
  void initState() {
    super.initState();
    service.ensureLoaded();
    // 监听 controller 而不是用 TextField.onChanged：
    // 点「×」清空、收起时清空都是**程序化** clear()，不会触发 onChanged，
    // 只挂 onChanged 会让 `_query` 停在旧值（列表显示的还是过滤后的结果）。
    _searchCtrl.addListener(() {
      if (!mounted) return;
      setState(() => _query = _searchCtrl.text);
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 过滤 + 排序后的「已安装」程序（内置那几张卡不参与）
  List<MiniApp> _visibleApps() {
    var list = service.apps.toList();
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where((a) =>
              a.name.toLowerCase().contains(q) ||
              a.source.toLowerCase().contains(q))
          .toList();
    }
    switch (_sort) {
      case _AppSort.custom:
        break;
      case _AppSort.name:
        list.sort((a, b) => a.name.compareTo(b.name));
      case _AppSort.newest:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
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
                  AppTheme.spacingMD,
                  AppTheme.spacingMD,
                  AppTheme.spacingMD,
                  0,
                ),
                child: Row(
                  children: [
                    // 左：标题「程序」
                    // （原来是"搜索时把标题整条换成输入框"，现在搜索框自带走起，
                    //   标题始终在，和影视首页一致）
                    Text(
                      '程序',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    // 右：搜索 / 设置 / 添加
                    // 搜索只作用于「已安装」，在「市场」Tab 下不显示（免得是个死按钮）
                    //
                    // 🔴 2026-10-14：换成影视首页同一个 `HomeSearchBar`
                    // （用户："程序的搜索图标点开后的框和影视不一样"）。
                    // 原来这里是个自带 `OutlineInputBorder` 的裸 TextField：
                    // 方角描边、撑满整行，和影视那个"圆钮→透明小胶囊"完全是两套东西。
                    if (_tab == 0)
                      HomeSearchBar(
                        hintText: '搜索程序',
                        controller: _searchCtrl,
                        // 已安装列表是本地过滤，不需要"进搜索页"，空提交即收起
                        onSubmitted: (_) {},
                        onTapEmpty: () {},
                      ),
                    const SizedBox(width: 4),
                    _topIcon(Icons.tune_rounded, '设置', _showSettingsSheet),
                    _topIcon(Icons.add_circle_outline, '添加程序', _showAddSheet),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.spacingSM),

              // ── 双 Tab：已安装 / 市场（对齐参考图，选中项带下划线指示条）──
              _tabBar(),
              const SizedBox(height: AppTheme.spacingSM),

              // IndexedStack：切 Tab 不丢市场那屏的滚动/已加载清单
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    Obx(() => _buildBody()),
                    _marketVisited
                        ? MiniAppMarketView(
                            initialUrl: _pendingMarketUrl,
                            initialList: _pendingMarketList,
                            onInstalled: () => setState(() {}),
                          )
                        : const SizedBox.shrink(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶部双 Tab（参考图 1：等宽两格 + 选中下划线）
  Widget _tabBar() {
    const tabs = ['已安装', '市场'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMD),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _switchTab(i),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tabs[i],
                      style: TextStyle(
                        color: _tab == i
                            ? AppTheme.textPrimary
                            : AppTheme.textTertiary,
                        fontSize: AppTheme.fontSubhead + 1,
                        fontWeight:
                            _tab == i ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      height: 2,
                      width: _tab == i ? 28 : 0,
                      decoration: BoxDecoration(
                        color: AppTheme.accentColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _switchTab(int i) async {
    if (i == _tab) return;
    // ⚠️ 顺序很重要：市场地址存在 prefs 里，必须**先读出来再建市场 Tab**
    //   —— MarketView 的 initState 只会读一次 `service.marketUrl`，
    //   读早了拿到空串 → 地址栏空白、也不会自动加载（看着像"没记住地址"）。
    if (i == 1) await service.ensureLoaded();
    if (!mounted) return;
    // 切到「市场」时搜索框会被移除（那里的搜索只作用于已安装列表），
    // 不清空的话回到「已安装」会看到"列表被过滤过、但输入框是收起的"。
    // 放在 setState 外面：clear() 会同步触发上面挂的监听器，那里已经 setState 了。
    if (i != 0) _searchCtrl.clear();
    setState(() {
      _tab = i;
      _marketVisited = true;
    });
  }

  // ── 顶栏小图标 ────────────────────────────────────────────────
  Widget _topIcon(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 21, color: AppTheme.textPrimary),
        ),
      ),
    );
  }

  // ── 主体：已装程序（网格/列表、可搜索/排序）────────
  Widget _buildBody() {
    final apps = _visibleApps();
    if (apps.isEmpty) {
      return Center(
        child: Text(
          _query.trim().isEmpty ? '还没有程序，点右上角 + 导入' : '没有匹配的程序',
          style: TextStyle(color: AppTheme.textTertiary, fontSize: 13),
        ),
      );
    }
    if (!_gridMode) {
      // 列表模式：一行一个（长按同样出菜单）
      return ListView(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.spacingMD, 0, AppTheme.spacingMD, 110),
        children: [
          for (final a in apps)
            _listRow(
              title: a.name,
              subtitle: _appTag(a),
              onTap: () => _openApp(a),
              onLongPress: () => _showAppMenu(a),
            ),
        ],
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spacingMD,
        0,
        AppTheme.spacingMD,
        110,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        // 用户 2026-10-13：默认视图**一排 4 个**
        //（原来用 maxCrossAxisExtent:140 在 iPhone 上算出 3 列）
        crossAxisCount: 4,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        // 4 列后卡宽 ≈76~80pt，卡内固定 52pt 图标 + 两行文字已接近高度上限，
        // 窄屏（iPhone SE 375pt）下 0.68 会差一点点 → RenderFlex overflow，
        // 故放宽到 0.62 留余量。
        childAspectRatio: 0.62,
      ),
      itemCount: apps.length,
      itemBuilder: (context, index) {
        final app = apps[index];
        return _MiniAppCard(
          app: app,
          // 稳定随机色：按 id（不是 name —— 同名不同来源要能区分）取色
          tint: _tintFor(app.id.isNotEmpty ? app.id : app.name),
          onTap: () => _openApp(app),
          onLongPress: () => _showAppMenu(app),
        );
      },
    );
  }

  /// 程序副标题：影视 N / 频道 N / 在线站点…
  String _appTag(MiniApp app) {
    if (app.isWebApp) {
      return app.source.startsWith('http') ? '在线站点' : '本地网页程序';
    }
    if (app.isMaiyou) return '直播订阅 · 麦优';
    final parsed = app.parsed;
    final videoCount = parsed.cmsSites.length + parsed.spiderSites.length;
    final liveCount =
        parsed.liveGroups.fold<int>(0, (sum, g) => sum + g.channels.length);
    return [
      if (videoCount > 0) '影视 $videoCount',
      if (liveCount > 0) '频道 $liveCount',
      if (parsed.hasInlineSpider) '内嵌脚本',
    ].join(' · ');
  }

  /// 打开程序（按类型分派：网页型 / 麦优订阅 / TVBox 配置）
  void _openApp(MiniApp app) {
    if (app.isWebApp) {
      final src = app.source;
      final isRemote = src.startsWith('http');
      Get.to(() => MiniAppWebPage(
            remoteUrl: isRemote ? src : null,
            localRoot: isRemote ? null : src,
            manifestJson: app.rawJson,
          ));
      return;
    }
    if (app.isMaiyou) {
      Get.to(() => MiniAppMaiyouPage(appId: app.id));
      return;
    }
    Get.to(() => MiniAppDetailPage(appId: app.id));
  }

  Widget _listRow({
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    // 行式卡片对齐参考图与「市场」Tab：**彩色首字图标 + 标题 + 副标题 + 右侧箭头**
    final tint = _tintFor(title);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      color: tint,
                    ),
                    child: Text(
                      title.isNotEmpty ? title.characters.first : '程',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: AppTheme.textTertiary, fontSize: 11)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded,
                      size: 18, color: AppTheme.textTertiary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const _tints = <Color>[
    Color(0xFF4FC3F7),
    Color(0xFF9575CD),
    Color(0xFF66BB6A),
    Color(0xFFFFA726),
    Color(0xFFEF5350),
    Color(0xFF26A69A),
  ];

  /// 按名称稳定取色（不用 String.hashCode：不保证跨进程稳定）
  Color _tintFor(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _tints[h % _tints.length];
  }

  // ── 设置弹层：排序 / 视图 / 调整顺序（行式排版，对齐参考图 2）──────
  //
  // 参考图 2 是「标题粗体 + 灰色说明小字 + 右侧控件」一行的排法，这里照抄这个
  // 信息结构；⚠️ 但**不照抄它那些设置项**（本地服务起始端口 / 最多同时后台运行 /
  // 在线网站广告过滤 / 混合合成模式 / 局域网共享）—— 那些能力本项目没有，
  // 放上去就是假开关。这里只列**真实存在**的三项，且改完即时生效，
  // 所以也不需要参考图底部那个「保存」按钮。
  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Text('程序设置',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                ),
                _settingRow(
                  title: '排序',
                  desc: '已安装列表按什么顺序排列',
                  control: Wrap(
                    spacing: 8,
                    children: [
                      for (final s in _AppSort.values)
                        _sheetChip(s.label, _sort == s, () {
                          setState(() => _sort = s);
                          setSheet(() {});
                        }),
                    ],
                  ),
                ),
                _settingDivider(),
                _settingRow(
                  title: '视图',
                  desc: '网格看图方便，列表信息更全',
                  control: Wrap(
                    spacing: 8,
                    children: [
                      _sheetChip('网格', _gridMode, () {
                        setState(() => _gridMode = true);
                        setSheet(() {});
                      }),
                      _sheetChip('列表', !_gridMode, () {
                        setState(() => _gridMode = false);
                        setSheet(() {});
                      }),
                    ],
                  ),
                ),
                if (service.apps.length > 1) ...[
                  _settingDivider(),
                  _settingRow(
                    title: '调整顺序',
                    desc: '长按拖动把手，重排已安装程序',
                    control: Icon(Icons.chevron_right_rounded,
                        color: AppTheme.textTertiary),
                    onTap: () {
                      Get.back();
                      _showReorderSheet();
                    },
                  ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 设置行（参考图 2 的排法）：左「标题 + 灰色说明」，右侧控件
  Widget _settingRow({
    required String title,
    required String desc,
    required Widget control,
    VoidCallback? onTap,
  }) {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead + 1,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(desc,
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                        height: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          control,
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }

  Widget _settingDivider() => Divider(
        height: 1,
        thickness: 0.5,
        indent: 20,
        endIndent: 20,
        color: AppTheme.borderLight,
      );

  Widget _sheetChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppTheme.accentColor : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderLight, width: 0.5),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? Colors.white : AppTheme.textSecondary,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
      ),
    );
  }

  // ── 长按菜单：分享 / 移动 / 删除 ──────────────────────────────
  void _showAppMenu(MiniApp app) {
    showModalBottomSheet(
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
            ListTile(
              leading:
                  Icon(Icons.share_outlined, color: AppTheme.textSecondary),
              title:
                  Text('分享', style: TextStyle(color: AppTheme.textPrimary)),
              onTap: () {
                Get.back();
                _shareApp(app);
              },
            ),
            ListTile(
              leading:
                  Icon(Icons.reorder_rounded, color: AppTheme.textSecondary),
              title:
                  Text('移动', style: TextStyle(color: AppTheme.textPrimary)),
              onTap: () {
                Get.back();
                _showReorderSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title:
                  const Text('删除', style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Get.back();
                _confirmRemove(app);
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  /// 分享：复制程序链接/配置到剪贴板（应用内没有分享 SDK，统一走复制）
  Future<void> _shareApp(MiniApp app) async {
    final text =
        app.source.trim().isNotEmpty ? app.source.trim() : app.rawJson;
    await Clipboard.setData(ClipboardData(text: text));
    AppToast.message('已复制程序链接');
  }

  /// 拖动排序（列表顺序即自定义顺序，落盘）
  void _showReorderSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Text('调整顺序',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text('拖动右侧把手',
                        style: TextStyle(
                            color: AppTheme.textTertiary, fontSize: 11)),
                  ],
                ),
              ),
              Expanded(
                child: Obx(
                  () => ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    itemCount: service.apps.length,
                    onReorder: (o, n) => service.reorder(o, n),
                    itemBuilder: (c, i) {
                      final a = service.apps[i];
                      return ListTile(
                        key: ValueKey(a.id),
                        title: Text(a.name,
                            style: TextStyle(color: AppTheme.textPrimary)),
                        subtitle: Text(_appTag(a),
                            style: TextStyle(
                                color: AppTheme.textTertiary, fontSize: 11)),
                        trailing: Icon(Icons.drag_handle_rounded,
                            color: AppTheme.textTertiary),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmRemove(MiniApp app) {
    Get.dialog(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('删除程序',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: Text(
          '删除「${app.name}」？其影视源会从视频源列表移除。',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Get.back();
              await service.remove(app);
              AppToast.message('已删除');
            },
            child: Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  // ── 添加 ──────────────────────────────────────────────────────
  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.textSecondary.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                '添加程序',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppTheme.spacingLG),
              _AddTile(
                icon: Icons.link,
                title: '网络导入',
                subtitle: 'TVBox 配置地址，或小程序市场链接',
                onTap: () {
                  Get.back();
                  _importFromUrlDialog();
                },
              ),
              const SizedBox(height: AppTheme.spacingMD),
              // 小程序市场：导入市场清单 → 列出里面的程序 → 点「安装」下载导入
              _AddTile(
                icon: Icons.storefront_outlined,
                title: '小程序市场',
                subtitle: '导入市场链接，列出里面的程序并安装',
                onTap: () {
                  Get.back();
                  _importFromUrlDialog();
                },
              ),
              const SizedBox(height: AppTheme.spacingMD),
              _AddTile(
                icon: Icons.content_paste,
                title: '粘贴 JSON',
                subtitle: '手动粘贴配置内容',
                onTap: () {
                  Get.back();
                  _importFromTextDialog();
                },
              ),
              const SizedBox(height: AppTheme.spacingMD),
              _AddTile(
                icon: Icons.folder_open,
                title: '本地文件',
                subtitle: '选择 .json 配置文件导入',
                onTap: () {
                  Get.back();
                  _importFromFile();
                },
              ),
              const SizedBox(height: AppTheme.spacingMD),
              _AddTile(
                icon: Icons.live_tv,
                title: '麦优直播订阅',
                subtitle: '输入麦优分类接口地址（json.txt）',
                onTap: () {
                  Get.back();
                  _importMaiyouDialog();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _importMaiyouDialog() async {
    final controller = TextEditingController();
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('添加麦优直播订阅',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              style: TextStyle(color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: '如 http://api.maiyoux.com:81/mf/json.txt',
                hintStyle: TextStyle(color: AppTheme.textSecondary),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppTheme.borderMedium),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '订阅后以独立应用打开：分类浏览 → 频道播放',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Get.back(result: true),
              child: const Text('添加')),
        ],
      ),
    );
    if (ok != true) return;
    final url = controller.text.trim();
    if (url.isEmpty) {
      AppToast.message('订阅地址不能为空');
      return;
    }
    await _run(() => MiniAppService.instance.importMaiyou(url));
  }

  Future<void> _importFromUrlDialog() async {
    final controller = TextEditingController();
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('网络导入',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'https://…/tvbox.json',
            hintStyle: TextStyle(color: AppTheme.textSecondary),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppTheme.borderMedium),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Get.back(result: false), child: const Text('取消')),
          TextButton(onPressed: () => Get.back(result: true), child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;
    final url = controller.text.trim();
    if (url.isEmpty) {
      AppToast.message('地址不能为空');
      return;
    }
    await _importByUrlSmart(url);
  }

  Future<void> _importFromTextDialog() async {
    final controller = TextEditingController();
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('粘贴 JSON',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: SizedBox(
          height: 220,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: null,
            expands: true,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: '{ "name": "…", "sites": […], "lives": […] }',
              hintStyle: TextStyle(color: AppTheme.textSecondary),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppTheme.borderMedium),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Get.back(result: false), child: const Text('取消')),
          TextButton(onPressed: () => Get.back(result: true), child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => service.importFromText(controller.text));
  }

  /// 网络导入 / 小程序市场：一次下载判断——
  /// 内容是市场清单 `{"apps":[…]}` → 打开市场页（列出 + 安装按钮）；
  /// 否则按普通 TVBox 配置导入。
  Future<void> _importByUrlSmart(String url) async {
    if (_busy) return;
    _busy = true;
    try {
      final r = await service.importUrlSmart(url);
      final market = r.market;
      if (!mounted) return;
      if (market != null) {
        // 市场清单 → 直接切到「市场」Tab，并带上已解析好的清单
        // （老版本是 push 一个独立市场页；参考图里市场就是程序页的一个 Tab）
        setState(() {
          _pendingMarketUrl = url;
          _pendingMarketList = market;
          _marketVisited = true;
          _tab = 1;
        });
      } else {
        AppToast.message(r.ok ? '导入成功' : (r.error ?? '导入失败'));
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        // zip = 小程序包（解包安装为网页型程序）；json/txt = TVBox 配置
        allowedExtensions: const ['json', 'txt', 'zip'],
      );
      if (result.isEmpty) return;
      final f = result.first;
      final path = f.path;
      if (path == null) {
        AppToast.message('读不出这个文件（没有本地路径）');
        return;
      }
      if (path.toLowerCase().endsWith('.zip')) {
        await _run(() => service.installFromZipFile(path));
        return;
      }
      await _run(() => service.importFromFile(path));
    } catch (e) {
      AppToast.message('选择文件失败: $e');
    }
  }

  Future<void> _run(
      Future<({bool ok, String? error})> Function() task) async {
    if (_busy) return;
    _busy = true;
    try {
      final result = await task();
      if (result.ok) {
        AppToast.message('导入成功');
      } else {
        AppToast.message(result.error ?? '导入失败');
      }
    } finally {
      _busy = false;
    }
  }
}

// ── 卡片 ────────────────────────────────────────────────────────
//
// 2026-10-14 改版（用户要求）：
//   · 去掉卡面上的「本地网页程序 / 在线站点 / 影视 N」副标题 —— 卡面只留封面；
//   · 名称位置：先按"移到卡片外面居中"做过一版，用户随后改主意 ——
//     最终要**压在封面底部、居中**（配一层底部压暗渐变保证白字可读）；
//   · 封面卡改成**每个程序一个稳定随机色**（按 id 哈希取色）——
//     同一个程序每次进来同色，不会每帧乱跳；不同程序之间颜色错开。
class _MiniAppCard extends StatelessWidget {
  final MiniApp app;

  /// 封面底色（由外层按 app.id 稳定取色后传入）
  final Color tint;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _MiniAppCard({
    required this.app,
    required this.tint,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final initial = app.name.isNotEmpty ? app.name.characters.first : '程';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: double.infinity,
        // antiAlias：底部那层压暗渐变要跟着圆角裁，否则四角会露出方角
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              tint.withValues(alpha: 0.92),
              tint.withValues(alpha: 0.60),
            ],
          ),
          // 用同色系投影代替玻璃描边：彩色卡配灰色描边会显脏
          boxShadow: [
            BoxShadow(
              color: tint.withValues(alpha: 0.28),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 首字：略往上挪，给底部名称留出位置，别挤在一起
            Align(
              alignment: const Alignment(0, -0.22),
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            // 底部压暗：白字直接压在彩色底上会糊，这层保证可读
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 46,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.45),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 名称：**压在封面底部、居中**（用户 2026-10-14）
            Positioned(
              left: 6,
              right: 6,
              bottom: 6,
              child: Text(
                app.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _AddTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Row(
          children: [
            Icon(icon, size: 22, color: AppTheme.textPrimary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18, color: AppTheme.textSecondary),
          ],
        ),
      ),
    );
  }
}
