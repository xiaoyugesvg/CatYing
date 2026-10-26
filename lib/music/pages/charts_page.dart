import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/services/settings_store.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart';
import 'package:tvbox/music/pages/playlist_detail_page.dart';

/// 「榜单」独立页（从音乐库拆出来的）。
///
/// ── 为什么要拆 ────────────────────────────────────────────────
/// 榜单原来挤在「音乐库」页面底部：那个页面已经有
/// 我的内容 / 正在播放 / 最近播放 / 我的收藏 四块，
/// 榜单再往下排会让人**滚很久才能看到**，而且它和"我的东西"性质不同
///（榜单是**发现**，不是"我的"）。
///
/// 拆成独立 tab 后：
///   · 音乐库 = 我自己的东西（收藏/最近/歌单/下载）
///   · 榜单   = 去发现（平台榜单）
/// 职责清楚，底栏也多一个能直达的入口。
class ChartsPage extends StatefulWidget {
  const ChartsPage({super.key});

  @override
  State<ChartsPage> createState() => _ChartsPageState();
}

class _ChartsPageState extends State<ChartsPage>
    with AutomaticKeepAliveClientMixin {
  final api = MusicApi.instance;

  /// 当前平台的榜单（跟 `SettingsStore.musicSource` 走）
  SongSource _source = SongSource.netease;
  List<TopList> _tops = const [];
  bool _loading = true;
  String _error = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _source = SettingsStore.instance.musicSource.value;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final src = SettingsStore.instance.musicSource.value;
    final r = await api.topListsResult(source: src);
    if (!mounted) return;
    setState(() {
      _source = src;
      _tops = r.list;
      _loading = false;
      // ⚠️ 区分"接口失败"和"该平台确实没榜单"：
      // QQ 免登录**有** 30 个榜单（实测），所以失败就是真失败；
      // 而喜马拉雅那种"本来就没有榜单"的平台要给不同文案。
      if (!r.ok && r.list.isEmpty) {
        _error = src == SongSource.ximalaya
            ? '喜马拉雅没有榜单（它是有声书平台）'
            : (r.error.isNotEmpty ? r.error : '榜单加载失败');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: MusicTheme.tint,
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 160),
          children: [
            // ── 标题 ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('榜单',
                        style: TextStyle(
                            color: MusicTheme.label,
                            fontSize: AppTheme.fontPageTitle,
                            fontWeight: FontWeight.w700)),
                  ),
                  // 平台标签：让用户知道"这是哪个平台的榜单"
                  //（切平台后榜单完全不同，不标出来会困惑）
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: MusicTheme.fill,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(_source.displayName,
                        style: TextStyle(
                            color: MusicTheme.secondary,
                            fontSize: AppTheme.fontCaption)),
                  ),
                ],
              ),
            ),

            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 60),
                child: Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              )
            else if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 40, 16, 0),
                child: Column(
                  children: [
                    Icon(Icons.cloud_off_rounded,
                        size: 40, color: MusicTheme.secondary),
                    const SizedBox(height: 12),
                    Text(_error,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: MusicTheme.secondary,
                            fontSize: AppTheme.fontBody)),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: MusicTheme.tint,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999)),
                      ),
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              )
            else if (_tops.isNotEmpty)
              // ── 卡片网格（用户 2026 要求）────────────────────────────
              //
              // 原来这里是 `RankListCard` —— 一个**大卡片内竖排**名次行。
              // 用户要求「榜单分类里面能不能卡片布局呢」→ 改成
              // **2 列卡片网格**，每张卡是：封面 + 榜名 + 更新频率，
              // 与「乐库」「歌单广场」的卡片观感统一。
              //
              // ⚠️ 高度必须**按可用宽度算**（`mainAxisExtent`），
              //    不能用固定 `childAspectRatio` —— 窄屏 + 系统大字号下
              //    内容会超出格子高（本项目踩过两次，见
              //    `ximalaya_category_page` / `library_page` 的同款注释）。
              _chartGrid(context),
          ],
        ),
      ),
    );
  }

  /// 榜单**卡片网格**（2 列）。
  ///
  /// 每张卡 = 封面（正方形，边长 = 格宽）+ 榜名（最多 2 行）+ 更新频率。
  ///
  /// ⚠️ 没有复用 `CoverCard`：它的 `width` 参数是**封面尺寸**（直接喂给
  /// `CoverImage(size:)`），传 `double.infinity` 会让封面撑爆格子。
  /// 而榜单要的是"封面跟着格宽走"，所以这里自己拼更直接。
  Widget _chartGrid(BuildContext context) {
    // 去掉左右 padding(16×2) 与列间距(12) 后每格宽度 ——
    // 封面的边长就用它（正方形，跟乐库卡片观感一致）
    final cellW = (MediaQuery.sizeOf(context).width - 16 * 2 - 12) / 2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 14,
          crossAxisSpacing: 12,
          mainAxisExtent: () {
            final ts = MediaQuery.textScalerOf(context);
            // 封面(cellW) + 间距 8 + 榜名 2 行 + 间距 2 + 更新频率 1 行 + 余量 8
            return cellW +
                8 +
                ts.scale(AppTheme.fontSubhead) * 1.35 * 2 +
                2 +
                ts.scale(AppTheme.fontCaption) * 1.35 +
                8;
          }(),
        ),
        itemCount: _tops.length,
        itemBuilder: (c, i) => _chartCard(context, _tops[i], cellW),
      ),
    );
  }

  Widget _chartCard(BuildContext context, TopList t, double cellW) {
    final freq = (t.updateFrequency ?? '').trim();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => openPlaylist(
        context,
        t.id,
        t.name,
        source: _source,
        // ⚠️ QQ 的 topId 不是歌单 id（用歌单接口查会得到空列表）
        isTopList: true,
        coverUrl: t.coverUrl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 封面：正方形，边长 = 格宽（与乐库卡片同款圆角 20）
          CoverImage(url: t.coverUrl, size: cellW, cornerRadius: 20),
          const SizedBox(height: 8),
          Text(
            t.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          // 更新频率：没有就不占位（少一行也更好看）
          if (freq.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              freq,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontCaption,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
