import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/services/music_api.dart';

/// 热搜关键词解析的**契约测试**（纯函数，不联网）。
///
/// ── 修的真实 bug（用户截图：QQ 音乐热搜格子显示 `{id: 0, name: 我们的歌}`）──
/// Node 侧 `hotSearch` **两条分支返回的形状不一样**：
///   · 网易云：`{ok:true, list:['周杰伦','林俊杰',…]}`       —— 字符串数组
///   · QQ    ：`{ok:true, list:[{id:'0',name:'我们的歌'},…]}` —— **对象数组**
///     （见 `qq_source.js` 的 `hotSearch`：`({ id: String(i), name: k })`）
///
/// Dart 侧原来统一 `l.map((e) => e.toString())`：
///   · 字符串 → 正常
///   · Map    → **`"{id: 0, name: 我们的歌}"`** ← 直接显示在界面上 ✗
///
/// 这个测试锁住"UI 最终拿到的字符串"这一层 —— 正是出问题的那一层。
void main() {
  test('🔴 QQ 形状（对象数组）必须取出 name，不能是 Map 字面量', () {
    // 照抄 qq_source.js 的真实输出
    final raw = [
      {'id': '0', 'name': '我们的歌'},
      {'id': '1', 'name': '冰雪奇缘2'},
      {'id': '2', 'name': '张杰'},
    ];
    final out = MusicApi.parseHotKeywords(raw);
    expect(out, ['我们的歌', '冰雪奇缘2', '张杰']);
    for (final k in out) {
      expect(k.contains('{'), isFalse, reason: '不能出现 Map 字面量：$k');
      expect(k.contains('id:'), isFalse, reason: '不能出现字段名：$k');
    }
    print('  QQ 形状 → $out');
  });

  test('网易云形状（字符串数组）原样返回（回归）', () {
    final raw = ['周杰伦', '林俊杰', '薛之谦'];
    expect(MusicApi.parseHotKeywords(raw), raw);
  });

  test('两种形状混在一起也能各自正确', () {
    final raw = [
      '周杰伦',
      {'id': '1', 'name': '冰雪奇缘2'},
      {'k': '热词A'},
      {'key': '热词B'},
      {'keyword': '热词C'},
    ];
    expect(MusicApi.parseHotKeywords(raw),
        ['周杰伦', '冰雪奇缘2', '热词A', '热词B', '热词C']);
  });

  test('Map 里没有可识别字段 → 丢弃（绝不能退回 toString）', () {
    // 这正是 bug 的根源：退回 toString() 就会显示 "{foo: bar}"
    final out = MusicApi.parseHotKeywords([
      {'foo': 'bar'},
      {'id': '9'}, // 只有 id，没有名字 → 无用，丢弃
      {'name': '有效项'},
    ]);
    expect(out, ['有效项'], reason: '无名字的项必须丢弃，不能变成 Map 字面量');
  });

  test('空值 / 非字符串 / 空白都要处理干净', () {
    expect(MusicApi.parseHotKeywords(null), isEmpty);
    expect(MusicApi.parseHotKeywords('不是数组'), isEmpty);
    expect(MusicApi.parseHotKeywords(const []), isEmpty);
    expect(MusicApi.parseHotKeywords(['', '   ', ' ok ']), ['ok']);
    expect(MusicApi.parseHotKeywords([null, 123, true]), ['123', 'true']);
  });

  test('name 不是字符串（数字 name）时也不崩', () {
    final out = MusicApi.parseHotKeywords([
      {'id': '0', 'name': 42},
      {'id': '1', 'name': '正常'},
    ]);
    // 数字 name 不属于 "String 且非空" → 丢弃；但绝不能崩
    expect(out, ['正常']);
  });
}
