import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/hiker/services/hiker_route.dart';

/// 「海阔详情页把地址翻成人话」的回归（用户 2026-10-16：
/// 「上面的地址就有问题……取地址要给我图片、正文、视频直链」）。
///
/// 核心是：**界面再也不裸露中间态地址**（`hiker://lazy#14uwff4`、
/// `{"urls":[…]}`），一律翻成「类型 + 真内容」。
void main() {
  test('延迟规则：不显示 id，说明"点一次才算得出"', () {
    final d = describeHikerLink('hiker://lazy#14uwff4');
    expect(d.kind, '延迟规则');
    expect(d.detail.contains('14uwff4'), isFalse);
    expect(d.detail.contains('点'), isTrue);
  });

  test('hiker://empty 及老写法 hiker://empty##地址##规则', () {
    expect(describeHikerLink('hiker://empty').kind, '提示');
    final d = describeHikerLink('hiker://empty##https://a.com/list##fypage');
    expect(d.kind, '提示');
    expect(d.detail, 'https://a.com/list');
  });

  test('播放 JSON → 露出里面真正的直链', () {
    final d = describeHikerLink(
        '{"urls":["https://hls.x.com/a/index.m3u8","备用"],"names":["HLS"]}');
    expect(d.kind, '播放 JSON');
    expect(d.detail, 'https://hls.x.com/a/index.m3u8');
  });

  test('视频直链 / 网页 / 提示', () {
    expect(describeHikerLink('https://x.com/a/index.m3u8').kind, '视频直链');
    expect(describeHikerLink('x5://https://a.com/1').kind, '网页');
    expect(describeHikerLink('x5://https://a.com/1').detail, 'https://a.com/1');
    final t = describeHikerLink('toast://没有播放地址');
    expect(t.kind, '提示');
    expect(t.detail, '没有播放地址');
  });

  test('图片：多图给张数，单图给地址', () {
    final list = describeHikerLink('pics://a.jpg&&b.png&&c.webp');
    expect(list.kind, '图片列表');
    expect(list.detail, '共 3 张图');
    final one = describeHikerLink('https://a.com/x/1.jpg');
    expect(one.kind, '图片');
    expect(one.detail, 'https://a.com/x/1.jpg');
  });

  test('正文：给字数', () {
    final d = describeHikerLink('novel://{"title":"第1章","content":"一二三四五"}');
    expect(d.kind, '正文');
    expect(d.detail, '共 5 字');
  });

  test('内部页 / 脚本 / 空 / 未知 —— 都有明确说法，不留空白', () {
    for (final u in [
      'hiker://page/setting',
      'javascript:void 0',
      '',
      'https://x.com/whatever',
    ]) {
      final d = describeHikerLink(u);
      expect(d.kind.isNotEmpty, isTrue, reason: 'kind 不能为空: $u');
      expect(d.detail.isNotEmpty, isTrue, reason: 'detail 不能为空: $u');
    }
  });
}
