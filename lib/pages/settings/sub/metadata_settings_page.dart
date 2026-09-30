import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../services/player_prefs.dart';
import '../../../services/tmdb_service.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';

/// 设置 → 元数据（TMDB 刮削）
///
/// 从原 settings/view.dart 拆出。两个开关（演职人员 / 类似作品）只控制
/// 详情页是否展示，数据仍会照常刮削并缓存 —— 关掉再开不必重新联网。
class MetadataSettingsPage extends StatelessWidget {
  const MetadataSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tmdb = TmdbService.instance;
    return SettingsSubPage(
      title: '元数据',
      children: [
        SettingsGroup(
          children: [
            SettingsRow(
              icon: Icons.movie_filter_outlined,
              title: 'TMDB API Key',
              value: tmdb.configured
                  ? '${tmdb.apiKey.value.substring(0, tmdb.apiKey.value.length.clamp(0, 6))}***'
                  : '未配置',
              onTap: () => _editKey(context),
            ),
            Obx(() => SettingsRow(
                  icon: Icons.auto_awesome,
                  title: '自动刮削元数据',
                  value: tmdb.autoScrape.value ? '已开启' : '已关闭',
                  onTap: () async {
                    await tmdb.setAutoScrape(!tmdb.autoScrape.value);
                  },
                )),
          ],
          hint: 'Key 可在 themoviedb.org 免费申请（v3）。自动刮削会在打开详情页时补全海报、简介与演职员。',
        ),
        SettingsGroup(
          title: '详情页展示',
          children: [
            Obx(() => SettingsRow(
                  icon: Icons.people_alt_outlined,
                  title: '显示演职人员',
                  value: tmdb.showCast.value ? '已开启' : '已关闭',
                  onTap: () async {
                    await tmdb.setShowCast(!tmdb.showCast.value);
                  },
                )),
            Obx(() => SettingsRow(
                  icon: Icons.local_movies_outlined,
                  title: '显示类似作品',
                  value: tmdb.showSimilar.value ? '已开启' : '已关闭',
                  onTap: () async {
                    await tmdb.setShowSimilar(!tmdb.showSimilar.value);
                  },
                )),
            Obx(() => SettingsRow(
                  icon: Icons.dashboard_customize_outlined,
                  title: '详情页样式',
                  value: PlayerPrefs.instance.scrapedDetailLayout.value
                      ? '刮削版'
                      : '默认',
                  onTap: () async {
                    final cur =
                        PlayerPrefs.instance.scrapedDetailLayout.value;
                    await PlayerPrefs.instance
                        .setScrapedDetailLayout(!cur);
                  },
                )),
          ],
          hint: '上面两个开关只控制「显示」，关掉不会清掉已刮削的缓存；'
              '详情页样式切换的是两套独立布局。',
        ),
      ],
    );
  }

  Future<void> _editKey(BuildContext context) async {
    final tmdb = TmdbService.instance;
    final key = await SettingsDialogs.editText(
      context: context,
      title: 'TMDB API Key',
      initial: tmdb.apiKey.value,
      hint: '粘贴 API Key (v3)',
      helper: '在 themoviedb.org → 设置 → API 里申请，形如 32 位十六进制字符串。',
    );
    if (key == null) return;
    await tmdb.saveApiKey(key);
  }
}
