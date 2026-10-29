import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/hiker/services/hiker_route.dart';
import 'package:tvbox/services/play_route.dart';

/// 「海阔」链接协议分流的回归测试。
///
/// 判定依据全部来自海阔**官方**：
///   · `ui/home/ArticleListFragment.java` → `dealWithUrl()`
///   · `ui/browser/model/UrlDetector.java` → `isImage()` / `isVideoOrMusic()`
///   · `app/src/main/assets/help_link.json` → 官方链接协议清单
/// 样本就用官方文档里那几条原文（`pics://` / `toast://` / `copy://` …）。
///
/// 不联网、不碰 SharedPreferences。
void main() {
  group('pics:// —— 多图模式（类似漫画）', () {
    test('官方样本：两张图用 && 连接', () {
      const u = 'pics://https://a.com/1.jpg&&https://a.com/2.jpg';
      expect(hikerLinkKind(u), HikerLinkKind.pics);
      expect(hikerPicList(u), ['https://a.com/1.jpg', 'https://a.com/2.jpg']);
    });

    test('必须排在"图片"之前 —— 否则退化成单张大图预览', () {
      // 这条 URL 里既有 pics:// 又有 .jpg 后缀；官方语义是多图
      const u = 'pics://https://a.com/1.jpg&&https://a.com/2.png';
      expect(hikerLinkKind(u), HikerLinkKind.pics);
      expect(hikerLinkKind(u), isNot(HikerLinkKind.image));
    });

    test('TVBox 同族写法 mange:// 也认', () {
      expect(
        hikerLinkKind('mange://https://a.com/1.jpg&&https://a.com/2.jpg'),
        HikerLinkKind.pics,
      );
    });
  });

  group('图片 —— 官方 UrlDetector.isImage 的后缀集合', () {
    test('jpg / png / gif / webp / jpeg / ico 都算图片', () {
      for (final ext in ['jpg', 'png', 'gif', 'webp', 'jpeg', 'ico']) {
        expect(
          hikerIsImageUrl('https://a.com/x.$ext'),
          isTrue,
          reason: '.$ext 应判为图片',
        );
        expect(
          hikerLinkKind('https://a.com/x.$ext'),
          HikerLinkKind.image,
          reason: '.$ext 应进图集阅读器',
        );
      }
    });

    test('三个官方守卫：x5Play / @rule= / ignoreImg=true 都不是图片', () {
      expect(hikerIsImageUrl('x5Play://http://a.com/1.jpg'), isFalse);
      expect(
        hikerIsImageUrl('https://a.com/1.jpg@rule=js:xxx'),
        isFalse,
        reason: '@rule= 是规则入口，要等规则求值',
      );
      expect(hikerIsImageUrl('https://a.com/1.jpg#ignoreImg=true#'), isFalse);
    });

    test('图片不能盖过影视直链判定（.mp4/.m3u8 仍是播放）', () {
      expect(hikerLinkKind('https://a.com/1.mp4'), HikerLinkKind.media);
      expect(hikerLinkKind('https://a.com/1.m3u8'), HikerLinkKind.media);
    });

    test('音频直链（音乐源 .mp3）也算播放，不能被丢去网页', () {
      expect(hikerLinkKind('https://a.com/1.mp3'), HikerLinkKind.media);
    });
  });

  group('提示类协议 —— 不该再丢给 WebView', () {
    test('官方样本 toast://加载失败，请换源', () {
      expect(hikerLinkKind('toast://加载失败，请换源'), HikerLinkKind.toast);
    });

    test('官方样本 copy://要复制的内容.js:\'http://1.com\'', () {
      const u = "copy://要复制的内容.js:'http://1.com'";
      expect(hikerLinkKind(u), HikerLinkKind.copyLink);
    });

    test('confirm:// / input:// / select:// 归到提示（本模块没有原生对话框）', () {
      expect(
        hikerLinkKind('confirm://确定吗.js:\'toast://已确认\''),
        HikerLinkKind.toast,
      );
      expect(
        hikerLinkKind('input://{"value":"","hint":"输入"}'),
        HikerLinkKind.toast,
      );
      expect(
        hikerLinkKind('select://{"title":"选择","options":["a","b"]}'),
        HikerLinkKind.toast,
      );
    });

    test('download:// 与 .apk 不走网页', () {
      expect(
        hikerLinkKind('download://http://a.com/1.mp4'),
        HikerLinkKind.download,
      );
      expect(hikerLinkKind('https://a.com/app/x.apk'), HikerLinkKind.apk);
    });
  });

  group('网页 / 播放类协议', () {
    test('官方：x5:// / x5WebView:// / web:// / video:// 都归网页类', () {
      expect(hikerLinkKind('x5://http://a.com'), HikerLinkKind.x5);
      expect(hikerLinkKind('x5WebView://http://a.com'), HikerLinkKind.x5);
      expect(hikerLinkKind('web://http://a.com'), HikerLinkKind.web);
      expect(
        hikerLinkKind('video://https://xxx.html'),
        HikerLinkKind.videoWeb,
      );
    });

    test('官方：x5Play:// 强制播放', () {
      const u = 'x5Play://http://a.com/1.mp4';
      expect(hikerLinkKind(u), HikerLinkKind.x5Play);
      expect(hikerStripScheme(u), 'http://a.com/1.mp4');
    });

    test('剥壳：x5:// / web:// / video:// / download://', () {
      expect(hikerStripScheme('x5://http://a.com'), 'http://a.com');
      expect(hikerStripScheme('web://http://a.com'), 'http://a.com');
      expect(
        hikerStripScheme('video://https://a.com/p.html'),
        'https://a.com/p.html',
      );
      expect(
        hikerStripScheme('download://http://a.com/1.mp4'),
        'http://a.com/1.mp4',
      );
      expect(
        hikerStripScheme('http://a.com/x'),
        'http://a.com/x',
        reason: '没有外壳时原样返回',
      );
    });

    test('javascript: 是彩蛋模式，不能当网页打开', () {
      expect(hikerLinkKind('javascript:var a = 1'), HikerLinkKind.js);
    });

    test('hiker:// 内部页面 / magnet 外部链接 / 普通网页', () {
      expect(hikerLinkKind('hiker://empty'), HikerLinkKind.hikerPage);
      expect(hikerLinkKind('hiker://search?s=测试'), HikerLinkKind.search);
      expect(hikerLinkKind('magnet:?xt=urn:btih:xxx'), HikerLinkKind.external);
      expect(hikerLinkKind('ftp://a.com/x'), HikerLinkKind.external);
      expect(hikerLinkKind('https://a.com/page.html'), HikerLinkKind.http);
    });

    test('hiker://search 深链：拆出源名与关键词（未编码中文也要认）', () {
      final a = parseHikerSearchUrl('hiker://search?rule=聚阅√&s=重生后我');
      expect(a?.rule, '聚阅√');
      expect(a?.keyword, '重生后我');
      final b = parseHikerSearchUrl(
        'hiker://search?keyword=%E6%B5%8B%E8%AF%95',
      );
      expect(b?.rule, '');
      expect(b?.keyword, '测试');
      expect(parseHikerSearchUrl('hiker://search'), isNotNull);
      expect(parseHikerSearchUrl('hiker://collection'), isNull);
    });

    test('@rule= 的链接不是图片也不是视频 —— 官方也是落到网页', () {
      expect(
        hikerLinkKind('https://a.com/1.jpg@rule=js:xxx'),
        HikerLinkKind.http,
      );
      expect(
        hikerLinkKind('https://a.com/play@lazyRule=js:xxx'),
        HikerLinkKind.http,
      );
    });
  });

  group('正文协议（项目内 TVBox 约定，与 pics 同层）', () {
    test('novel://{title,content} → 书籍阅读器', () {
      const u = 'novel://{"title":"第一章","content":"正文内容"}';
      expect(hikerLinkKind(u), HikerLinkKind.novel);
      final n = hikerNovelContent(u);
      expect(n?.title, '第一章');
      expect(n?.content, '正文内容');
    });

    test('非 JSON 的纯文本正文也认（少数源直接给纯文本）', () {
      const u = 'novel://第一章 正文内容';
      expect(hikerLinkKind(u), HikerLinkKind.novel);
      expect(hikerNovelContent(u)?.content, '第一章 正文内容');
    });

    test('只有 pics:// 才判多图；novel:// 不会被误判成图片', () {
      expect(hikerPicList('novel://{"content":"x"}'), isNull);
      expect(hikerIsImageUrl('novel://{"content":"x"}'), isFalse);
    });
  });

  group('播放地址 JSON（源把 {"urls":[…]} 当条目地址）', () {
    // 用户 2026-10-16 截图：详情页「选集 1/2/3」全带个「提示」按钮、点了没反应，
    // 因为条目地址就是这坨 JSON —— 以前只在整条规则的返回值里解析它。
    test('{urls:[m3u8]} 要判成可播放（不再落到"未知链接"）', () {
      const u =
          '{"urls":["https://hls.tpbbwcc.cn/v/xx/index.m3u8"],'
          '"names":["HLS"],"headers":{"Referer":"https://a.com/"}}';
      expect(hikerLinkKind(u), HikerLinkKind.playJson);
      expect(
        hikerLinkKind(u),
        isNot(HikerLinkKind.unknown),
        reason: '判成 unknown 就会显示"提示"、点了只弹 toast',
      );
      final pj = hikerPlayJson(u)!;
      expect(pj.urls, ['https://hls.tpbbwcc.cn/v/xx/index.m3u8']);
      expect(pj.headers['Referer'], 'https://a.com/');
      expect(
        looksLikeDirectMedia(pj.urls.first),
        isTrue,
        reason: '直链 ⇒ 进原生播放器',
      );
    });

    test('里面的地址是网页时 ⇒ 走 WebView', () {
      const u = '{"urls":["https://a.com/play.html"]}';
      expect(hikerLinkKind(u), HikerLinkKind.playJson);
      final pj = hikerPlayJson(u)!;
      expect(looksLikeDirectMedia(pj.urls.first), isFalse);
    });

    test('必须排在"图片"之前（urls 里带 .jpg 也不能当成图集）', () {
      const u = '{"urls":["https://a.com/1.jpg"]}';
      expect(hikerLinkKind(u), HikerLinkKind.playJson);
      expect(hikerLinkKind(u), isNot(HikerLinkKind.image));
    });

    test('不是播放 JSON 的一律 null', () {
      expect(hikerPlayJson('{"a":1}'), isNull);
      expect(hikerPlayJson('https://a.com/1.m3u8'), isNull);
      expect(hikerPlayJson('{"urls":[]}'), isNull);
    });
  });

  group('内联规则 `@rule=` / `@lazyRule=`（漫画源的目录页）', () {
    // 用户 2026-10-17：「海阔里面漫小肆脚本能有目录和漫画阅读功能吗」
    // 漫小肆的漫画条目地址 = 详情页 + `#immersiveTheme##autoCache#@rule=js:$.require("er")`
    test('@rule= 要拆出真实地址与 JS（flag 必须剥掉）', () {
      const u =
          'https://www.jjmhw2.top/book/1232'
          '#immersiveTheme##autoCache#@rule=js:\$.require("er")';
      final r = splitHikerInlineRule(u)!;
      expect(r.base, 'https://www.jjmhw2.top/book/1232');
      expect(r.code, 'js:\$.require("er")');
      expect(r.lazy, isFalse);
    });

    test('@lazyRule= 标记成 lazy（排序 / 切换按钮）', () {
      const u =
          "#noLoading#@lazyRule=.js:putVar('a','1');refreshPage();"
          "'toast://切換成功！';'#noHistory#hiker://empty'";
      final r = splitHikerInlineRule(u)!;
      expect(r.lazy, isTrue);
      expect(r.code.startsWith('.js:'), isTrue);
    });

    test('普通地址 / 空 code 返回 null（不能误伤正常链接）', () {
      expect(splitHikerInlineRule('https://a.com/book/1#noHistory#'), isNull);
      expect(splitHikerInlineRule('https://a.com/book/1@rule='), isNull);
      // 真实片段（没有收尾 #）不是 flag，不能裁掉
      const u = 'https://a.com/p#section@rule=js:x()';
      expect(splitHikerInlineRule(u)!.base, 'https://a.com/p#section');
    });

    test('带内联规则的地址不能被判成图片（官方 UrlDetector 同款守卫）', () {
      const u = 'https://a.com/1.jpg#autoCache#@rule=js:x()';
      expect(hikerIsImageUrl(u), isFalse);
    });
  });

  group('@Referer= 尾巴（漫画图片防盗链）', () {
    test('空值 = 用来源页当 Referer，且不能留在图片地址里', () {
      final r = splitHikerReferer('https://a.com/1.jpg@Referer=');
      expect(r.url, 'https://a.com/1.jpg');
      expect(r.referer, '');
    });

    test('显式值要取出来', () {
      final r = splitHikerReferer('https://a.com/1.jpg@Referer=https://b.com/');
      expect(r.url, 'https://a.com/1.jpg');
      expect(r.referer, 'https://b.com/');
    });

    test('没有尾巴时原样返回', () {
      final r = splitHikerReferer('https://a.com/1.jpg');
      expect(r.url, 'https://a.com/1.jpg');
      expect(r.referer, '');
    });
  });
}
