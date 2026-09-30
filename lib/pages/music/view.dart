import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/music_service.dart';
import '../settings/sub/music_source_settings_page.dart';

/// 音乐页（骨架）
///
/// 本轮只做**框架 + 音源对接层**：
///   - 顶部搜索框（接 [MusicService.search]）
///   - 结果列表（封面 + 歌名 + 歌手 + 时长）
///   - 未配置音源时给出引导，而不是空白页
///
/// 还没做的（等音源确定后再补）：播放器、歌单、收藏、歌词。
/// 这些留了明确的落点（见下方 TODO 注释），不会返工。
class MusicPage extends StatefulWidget {
  const MusicPage({super.key});

  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  MusicService get svc => MusicService.instance;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildSearchBar(),
            Expanded(
              child: Obx(() {
                // 未配置 → 引导去设置
                if (!svc.configured) return _buildEmptyGuide();
                if (svc.isSearching.value) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: AppTheme.accentColor),
                        ),
                        const SizedBox(height: 14),
                        Text('正在搜索…',
                            style: TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: AppTheme.fontSubhead)),
                      ],
                    ),
                  );
                }
                final list = svc.results;
                if (list.isEmpty) return _buildIdle();
                return _buildResultList();
              }),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 顶部
  // ============================================================

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingLG, AppTheme.spacingLG, 0),
      child: Row(
        children: [
          Text('音乐',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.bold)),
          const Spacer(),
          // 音源设置入口
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Get.to(() => const MusicSourceSettingsPage()),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(18),
                border:
                    Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.dns_outlined,
                      size: 14, color: AppTheme.accentColor),
                  const SizedBox(width: 5),
                  Text('音源',
                      style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontCaption)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingLG, AppTheme.spacingSM),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(21),
                border: Border.all(color: AppTheme.glassBorder, width: 0.8),
              ),
              child: Row(
                children: [
                  Icon(Icons.search,
                      size: 17, color: AppTheme.textTertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      cursorColor: AppTheme.accentColor,
                      cursorWidth: 2,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontSubhead + 1),
                      decoration: InputDecoration(
                        hintText: '搜索歌曲 / 歌手 / 专辑',
                        hintStyle: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontSubhead + 1),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (_) => _doSearch(),
                    ),
                  ),
                  if (_input.text.isNotEmpty)
                    GestureDetector(
                      onTap: () => setState(() => _input.clear()),
                      child: Icon(Icons.cancel,
                          size: 16, color: AppTheme.textTertiary),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _doSearch,
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.accentColor,
                borderRadius: BorderRadius.circular(21),
              ),
              child: const Text('搜索',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 空态
  // ============================================================

  Widget _buildEmptyGuide() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.library_music_outlined,
                  size: 32, color: AppTheme.accentColor),
            ),
            const SizedBox(height: 18),
            Text('还没有配置音乐音源',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead + 2,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              '填一个兼容协议的 HTTP 音源地址即可开始搜索。\n'
              'App 本身不内置任何音源。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                  height: 1.5),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Get.to(() => const MusicSourceSettingsPage()),
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.accentColor,
                  borderRadius: BorderRadius.circular(21),
                ),
                child: const Text('去配置音源',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIdle() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.music_note_outlined,
              size: 40,
              color: AppTheme.textTertiary.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text('输入关键词开始搜索',
              style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: AppTheme.fontSubhead)),
          const SizedBox(height: 6),
          Obx(() {
            final err = svc.lastError.value;
            if (err.isEmpty) return const SizedBox.shrink();
            return Text(err,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: AppTheme.fontCaption));
          }),
        ],
      ),
    );
  }

  // ============================================================
  // 结果
  // ============================================================

  Widget _buildResultList() {
    return Obx(() {
      final list = svc.results;
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.spacingLG, 4, AppTheme.spacingLG, 110),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) => _trackRow(list[i]),
      );
    });
  }

  Widget _trackRow(MusicTrack t) {
    return GestureDetector(
      // TODO(音乐播放): 接入播放器后改为播放该曲目
      behavior: HitTestBehavior.opaque,
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('播放功能待接入（先确认音源协议）')),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Row(
          children: [
            // 封面
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 46,
                height: 46,
                child: t.coverUrl.isEmpty
                    ? _coverPlaceholder()
                    : Image.network(
                        t.coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _coverPlaceholder(),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t.title,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontSubhead + 1,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (t.artist.isNotEmpty) t.artist,
                      if (t.album.isNotEmpty) t.album,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 音质标签
            if (t.quality.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.accentColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(t.quality,
                    style: TextStyle(
                        color: AppTheme.accentColor,
                        fontSize: 9,
                        fontWeight: FontWeight.w600)),
              ),
            const SizedBox(width: 8),
            Text(t.durationText,
                style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                    fontFamily: 'monospace')),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _coverPlaceholder() => ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: Icon(Icons.music_note,
            size: 20, color: AppTheme.textTertiary),
      );

  Future<void> _doSearch() async {
    final kw = _input.text.trim();
    if (kw.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入关键词')));
      return;
    }
    _focus.unfocus();
    final r = await svc.search(kw);
    if (!mounted) return;
    if (r.tracks.isEmpty && r.message.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(r.message)));
    }
  }
}
