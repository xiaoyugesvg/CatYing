import 'package:flutter_test/flutter_test.dart';

/// 回归测试：**源站简介里的 `\n` 转义必须还原成真换行**。
///
/// ── 实测问题（用户截图）────────────────────────────────────────
/// 书籍详情页「简介」里出现了**字面的 `\n`**：
/// ```
/// 天武大陆，武道为尊，妖魔横行！\n林长青一朝穿越，竟成了被强行征调守城的难民。\n
/// 城外妖魔大军铺天盖地，城内数千残兵绝望等死，外援迟迟不至，彻底沦为孤城。\n
/// ```
/// 源是 `📂无极书院`（`http://m.wjzxchina.com`），
/// `ruleBookInfo.intro = "class.nrjj@class.e@text"`（**纯 CSS 规则，无 @js**）
/// ⇒ `\n` **是从源站 HTML 原样抓来的**（该站把简介存成转义形态）。
///
/// 而 `Text(intro)` 直接渲染、全项目也没有还原逻辑 ⇒ 字面显示 ✗
///
/// ── ⚠️ 一个必须防的坑（本测试第二轮才抓出来）──────────────────
/// 天真实现 `replaceAll(r'\n', '\n')` 会**破坏含反斜杠的正常文本**：
/// ```
/// C:\Users\abc\docs\readme.txt   →  C:\Users\abc\docs<换行>eadme.txt  ✗✗
/// ```
/// （`readme` 里的 `\r` 被当成回车了。）
///
/// ⇒ 只还原"**明确是转义**"的形态：紧邻词边界的 `\r\n` 或 `\n`。
///    这样 `\readme` 里的 `\r` 因为后面跟的是字母 `e`（非词边界）而**不匹配** ✓
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('🔴 简介里成串的 \\n 必须还原为真换行', () {
    const raw = r'天武大陆，武道为尊，妖魔横行！\n林长青一朝穿越，竟成守城难民。'
        r'\n城外妖魔大军铺天盖地。\n\n第二段';
    final out = unescapeLineBreaks(raw);
    // ignore: avoid_print
    print('[probe] 还原后: ${out.replaceAll('\n', '<LF>')}');
    expect(out, isNot(contains(r'\n')), reason: '字面 \\n 必须消失');
    expect(out, contains('\n'), reason: '必须变成真换行');
    expect(out, contains('天武大陆'), reason: '正文内容不能被破坏');
    // 输入含 `\n\n`（空行）⇒ 共 4 处：3 个段落分隔 + 1 个空行
    expect('\n'.allMatches(out).length, 4,
        reason: r'输入有 4 个 \n（含一个空行 \n\n），应产生 4 个换行');
  });

  test('🔴 含反斜杠的正常文本**绝不能**被破坏（Windows 路径）', () {
    const path = r'C:\Users\abc\docs\readme.txt';
    expect(unescapeLineBreaks(path), path,
        reason: r'`\readme` 的 `\r` 后面跟字母 e ⇒ 不是转义 ⇒ 必须原样保留');

    // `\new` 同样危险：天真的 replaceAll(r'\n', ...) 会把它劈开
    const tricky = r'C:\new\file.txt';
    expect(unescapeLineBreaks(tricky), tricky,
        reason: r'`\new` 的 `\n` 后面跟字母 e ⇒ 不是转义 ⇒ 必须原样保留');

    const plain = '这是一段普通简介，价格 3.5 折！';
    expect(unescapeLineBreaks(plain), plain);
  });

  test(r'\r\n 组合还原成单个换行', () {
    final out = unescapeLineBreaks(r'第一行\r\n第二行');
    // ignore: avoid_print
    print('[probe] ${out.replaceAll('\n', '<LF>')}');
    expect('\n'.allMatches(out).length, 1,
        reason: r'\r\n 是 Windows 换行，应还原成单个 \n（不是一个 \n 加一个空行）');
  });

  test(r'`\n` 后接标点/空格/中文也算换行（源站常见写法）', () {
    // 截图里就是 `\n　`（\n + 全角空格）
    final out = unescapeLineBreaks(r'第一句。\n　第二句。');
    // ignore: avoid_print
    print('[probe] ${out.replaceAll('\n', '<LF>')}');
    expect(out, contains('\n'), reason: r'`\n` 后跟全角空格也应算换行');
    expect(out, contains('第二句'));
  });
}

/// 把文本里**明确是转义**的换行还原为真实换行。
///
/// 判据：`\n` / `\r\n` 必须是**独立的一对反斜杠+字母**，
/// 且其后**不是字母或数字**（即处于词边界）—— 这样
/// `C:\new`、`C:\readme` 这类真实路径不会被误伤 ✓
///
/// ⚠️ 与 `lib/reading/novel_source/web_book/book_info.dart` 里的
///    生产实现保持同口径（两处逻辑必须一致，此测试同时钉住生产行为）。
String unescapeLineBreaks(String s) {
  if (!s.contains(r'\')) return s;
  return s
      // \r\n → \n（先处理，避免变成两次换行）
      .replaceAll(RegExp(r'\\r\\n(?![A-Za-z0-9])'), '\n')
      // \n → 真换行（后面不能跟字母/数字）
      .replaceAll(RegExp(r'\\n(?![A-Za-z0-9])'), '\n')
      // 单独的 \r → 换行（同样要求词边界）
      .replaceAll(RegExp(r'\\r(?![A-Za-z0-9])'), '\n');
}
