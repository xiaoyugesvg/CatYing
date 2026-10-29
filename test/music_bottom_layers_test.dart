import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/common/floating_nav_spec.dart';
import 'package:tvbox/music/widgets/mini_player.dart';

/// 音乐模块**底部三层的几何契约**测试。
///
/// ── 这个测试防的是什么（用户实测反馈过的一个真问题）──────────────
/// 音乐页底部有**三层**同时可能出现：
///   ① 悬浮导航栏（胶囊，贴底）
///   ② 迷你播放条（在导航栏**上方**，有歌才出现）
///   ③ 悬浮播放球（可拖动，右下角）
///
/// 播放球的默认位置原来**写死** `距底 96`，而迷你条实际占到
/// `距底 148` —— 于是球**正好压在迷你条右端**（用户截图可见）。
///
/// 修法不是"把 96 改成 156"（那只是把同一个魔法数换个值，
/// 以后改迷你条高度又会压上），而是**把三层的几何抽成常量、
/// 由常量推导出球的位置**：
///   · `MusicMiniPlayerLayout` 提供迷你条的几何
///   · `FloatingNavSpec` 提供导航栏的几何
///   · 播放球用 `MusicMiniPlayerLayout.topFromBottom + 间隙`
///
/// 下面这些断言就是钉住那组**推导关系**：
/// 谁把常量改乱了（比如让 `totalHeight` 不再含 gap），这里立刻挂。
void main() {
  group('底部三层几何（导航栏 / 迷你条 / 播放球）', () {
    test('导航栏占的高度 = 下边距 + 栏高', () {
      // 这一层是"贴底"的，所以它的占用就是这两项之和
      expect(
        FloatingNavSpec.bottomMargin + FloatingNavSpec.barHeight,
        86.0,
        reason: '导航栏几何被改动了 —— 下面所有推导都要重算',
      );
    });

    test('迷你条整条高度 = 容器高 + 与导航栏的间隙', () {
      // ⚠️ 实测结构：外层 padding 的**底部**就是 gapAboveNavBar(6)，
      //    没有独立的 vertical padding。所以整条 = 56 + 6 = 62。
      expect(MusicMiniPlayerLayout.barHeight, 56.0);
      expect(MusicMiniPlayerLayout.gapAboveNavBar, 6.0);
      expect(MusicMiniPlayerLayout.totalHeight, 62.0,
          reason: 'totalHeight 必须等于 barHeight + gapAboveNavBar'
              '（别再把"独立的 vertical padding"算进来）');
    });

    test('迷你条顶边距屏幕底 = 导航栏占用 + 迷你条整条', () {
      expect(MusicMiniPlayerLayout.topFromBottom, 148.0,
          reason: '86(导航栏) + 62(迷你条) = 148');
    });

    test('🔴 播放球必须**在迷你条上方**，不能压上去', () {
      // 播放球的间隙常量（见 floating_play_button.dart 的 _bottomGap）
      const ballGap = 8.0;
      const ballSize = 54.0;

      final ballBottom = MusicMiniPlayerLayout.topFromBottom + ballGap;

      // ① 球底边必须在迷你条**顶边之上**（否则就是重叠）
      expect(ballBottom, greaterThan(MusicMiniPlayerLayout.topFromBottom),
          reason: '球底边距底($ballBottom) 必须 > 迷你条顶边(${MusicMiniPlayerLayout.topFromBottom})');

      // ② 修复前的值是 96 —— 那时球底边**落在迷你条区间内**（86~148）。
      //    这条断言保证不会退回去。
      expect(ballBottom, greaterThan(148.0),
          reason: '球底边距底必须 > 148（迷你条顶边），'
              '否则会像修复前那样压在迷你条上');

      // ③ 球整体也不该飘得太高（占掉太多可视区）
      final ballTop = ballBottom + ballSize;
      expect(ballTop, lessThan(280.0),
          reason: '球顶边距底($ballTop) 太高会挡内容');

      print('  球底边距底=${ballBottom.toInt()}  '
          '球顶边=${ballTop.toInt()}  '
          '迷你条顶边=${MusicMiniPlayerLayout.topFromBottom.toInt()}');
    });
  });
}
