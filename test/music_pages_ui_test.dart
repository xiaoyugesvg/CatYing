// 音乐「乐库 / 榜单 / 我的」三屏 UI 守卫（2026-10-31）。
//
// ── 为什么需要它 ───────────────────────────────────────────────
// 用户两次说同一件事：
//   「音乐推荐和分类里面的 UI 界面还是不够，用你之前生成的设计图片样式呢」
//   「音乐推荐和分类里面的UI界面还是不够」
//
// 设计稿在 `outputs/music_ui/`（9 屏），但代码里只落地了「发现页」一屏，
// 乐库 / 榜单 / 我的三屏一直没人动 —— **单测抓不到「没做」这件事**。
//
// 所以这里用静态守卫盯着：三屏必须真的用上设计稿那套组件。
// 谁以后把它们改回网格/裸列表，这里会红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/music/widgets/mo_lv_pages.dart';

String _read(String relative) => File(relative).readAsStringSync();

/// 去掉注释，避免「注释里写了组件名」就让测试误判通过
String _stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlock
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i < 0 ? line : line.substring(0, i);
      })
      .join('\n');
}

void main() {
  group('时长格式化（行列表右侧那串）', () {
    test('正常秒数', () {
      expect(formatDuration(222), '3:42');
      expect(formatDuration(195), '3:15');
      expect(formatDuration(248), '4:08');
    });

    test('补零', () {
      expect(formatDuration(65), '1:05');
      expect(formatDuration(9), '0:09');
    });

    test('未知时长不显示 0:00（会让人以为歌是空的）', () {
      expect(formatDuration(0), '--:--');
      expect(formatDuration(-1), '--:--');
      expect(formatDuration(double.nan), '--:--');
    });
  });

  group('乐库：设计稿 02', () {
    final src = _stripComments(_read('lib/music/pages/library_page.dart'));

    test('「我的歌单」是横滑方卡，不是导航行', () {
      expect(src.contains('MoLvShelf('), isTrue,
          reason: '设计稿 02 的「我的歌单」是一排方形卡片（封面 + N 首），'
              '不是一行「我的歌单 3」的导航条');
    });

    test('「最近播放」是行列表，不是 2 列网格', () {
      expect(src.contains('MoLvTrackList('), isTrue);
      expect(src.contains('_cardGrid('), isFalse,
          reason: '网格一屏只放 4 首，单曲用行列表更紧凑（设计稿 02 就是三行）');
    });

    test('点歌从整个列表的对应位置起播（「下一首」才对）', () {
      expect(src.contains('playQueue(_recent, index: i)'), isTrue);
      expect(src.contains('playQueue(_favorites, index: i)'), isTrue);
    });
  });

  group('榜单：设计稿 03', () {
    final src = _stripComments(_read('lib/music/pages/charts_page.dart'));

    test('顶部有平台胶囊行（不用绕到设置里切音源）', () {
      expect(src.contains('MoLvChipRow('), isTrue);
      expect(src.contains('setMusicSource('), isTrue,
          reason: '胶囊点了要真的切音源，否则只是个装饰');
    });

    test('歌曲行是编号样式（01/02/03 前三名 accent）', () {
      expect(src.contains('MoLvRankRow('), isTrue);
    });

    test('「播放全部」点了直接播，不是跳详情页', () {
      expect(
        src.contains('playQueue(_songs)'),
        isTrue,
        reason: '原来这个位置是 openPlaylist（跳进详情页再看一遍），名不副实',
      );
    });

    test('不编造排名升降箭头（本 App 没有排名快照）', () {
      expect(src.contains('↑'), isFalse);
      expect(src.contains('↓'), isFalse);
      expect(
        _read('lib/music/widgets/mo_lv_pages.dart').contains('排名快照'),
        isTrue,
        reason: '要在注释里写清楚为什么不显示升降箭头，'
            '否则以后有人会以为是漏做了',
      );
    });
  });

  group('我的：设计稿 08', () {
    test('顶部有「本地模式」卡', () {
      final src = _stripComments(_read('lib/music/pages/profile_page.dart'));
      expect(src.contains('MoLvUserCard('), isTrue);
      expect(src.contains('本地模式'), isTrue);
    });

    test('没有把「我的」大标题加回来（用户 2026-10-30 明确要求去掉）', () {
      final src = _stripComments(_read('lib/music/pages/profile_page.dart'));
      expect(
        src.contains("MusicPageHeader("),
        isFalse,
        reason: '底栏 tab 已经写着「我的」，页内再顶一个大标题纯属重复',
      );
    });
  });
}
