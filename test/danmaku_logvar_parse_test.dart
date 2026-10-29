import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/widgets/danmaku.dart';

/// LogVar 弹幕 API（`dm.muiu.site/20060709`）真实响应的解析测试。
///
/// ── 背景（用户实测反馈）──────────────────────────────────────────
/// 用户把 `https://dm.muiu.site/20060709` 填进弹幕地址后**所有片都不显示**。
///
/// 实测该站点接口（`https://dm.muiu.site/20060709/api/v2/comment/13000`）：
/// ```json
/// {"count":3410,"comments":[
///   {"cid":1,"p":"0.00,1,13469695,[qq]","m":"佐助还是那么的高冷","t":0,"like":4},
///   ...]}
/// ```
///
/// ── 这个测试要回答的问题 ────────────────────────────────────────
/// **解析器到底吃不吃这个格式？**
///   · 吃 → 那"所有片都不显示"的原因在别处（开关 / 地址 / 网络）
///   · 不吃 → 就是解析问题，得修 `parseDanmuBody`
///
/// 下面用**真实响应片段**（照抄自实测）来钉。
void main() {
  /// 真实响应的首几条（照抄，未改字段）
  const realBody = '{"count":4,"comments":['
      '{"cid":1,"p":"0.00,1,13469695,[qq]","m":"佐助还是那么的高冷","t":0,"like":4},'
      '{"cid":2,"p":"0.00,1,16777215,[qq]","m":"我要哭了","t":0,"like":1},'
      '{"cid":3,"p":"125.50,1,16777215,[qq]","m":"中间一条","t":125500,"like":3},'
      '{"cid":4,"p":"60.20,4,16711680,[qq]","m":"顶部红字","t":60200,"like":0}'
      ']}';

  test('🔴 LogVar 真实响应必须能解析出弹幕（否则"所有片都不显示"是解析问题）',
      () {
    final items = parseDanmuBody(realBody);
    // ignore: avoid_print
    print('[probe] 解析出 ${items.length} 条');
    for (final d in items) {
      // ignore: avoid_print
      print('[probe]   time=${d.time} mode=${d.mode} '
          'color=0x${d.color.toARGB32().toRadixString(16)} text=${d.text}');
    }

    expect(items.length, 4,
        reason: '这个格式响应里有 4 条，解析器必须全部拿到。'
            '若为 0 = 解析器不认 LogVar 格式 → 修 `parseDanmuBody`');

    // ① 时间：`p` 第 1 段是**秒**
    expect(items[0].time, 0.0);
    expect(items[2].time, closeTo(125.50, 0.01),
        reason: '`p` 第一段是秒；注意不能被同条的 `t`（毫秒）覆盖错');
    // ② 模式：`p` 第 2 段（1 滚动 / 4 顶部）
    expect(items[0].mode, 1);
    expect(items[3].mode, 4, reason: '`p` 第二段 = 4 时应识别为顶部弹幕');
    // ③ 颜色：`p` 第 3 段
    expect(items[0].color.toARGB32() & 0xFFFFFF, 13469695,
        reason: '`p` 第三段是颜色（不带 alpha 的 RGB 整数）');
    // ④ 文本：`m` 字段
    expect(items[0].text, '佐助还是那么的高冷',
        reason: '文本在 `m` 字段（不是 `text`/`content`）');
  });

  test('🔴 `t` 字段会覆盖 `p` 的时间吗（这是个隐患点）', () {
    // 实测响应里 `t` 与 `p[0]` **不一致**：
    //   p="125.50,..."  vs  t=125500（毫秒，= 125.5 秒）
    // 若解析器先读 `p` 再被 `t` 覆盖，或反之，都需要是**同一个值**。
    final items = parseDanmuBody(realBody);
    expect(items[2].time, closeTo(125.5, 0.01),
        reason: '`t`=125500 是毫秒、`p[0]`=125.50 是秒，两者应解析成同一时刻；'
            '差 1000 倍会让弹幕出现在错误位置（或永不出现）');
  });

  test('兼容：`p` 缺失时退回 `t` / `timepoint` / `progress`', () {
    // 有的源不给 `p`
    final a = parseDanmuBody(
        '[{"t":30000,"m":"只有t","cid":9}]');
    expect(a.length, 1);
    expect(a.first.time, 30.0, reason: 't=30000 毫秒 → 30 秒');
    expect(a.first.text, '只有t');

    final b = parseDanmuBody('[{"timepoint":45000,"content":"只有timepoint"}]');
    expect(b.length, 1);
    expect(b.first.time, 45.0);

    final c = parseDanmuBody('[{"progress":1200,"content":"只有progress"}]');
    expect(c.length, 1);
    expect(c.first.time, 1.2, reason: 'progress 是毫秒 → 1.2 秒');
  });
}
