// lib/services/xbpq/xbpq_template.dart
//
// XBPQ 内置模板 —— 对齐 huoyi `provider_xbpq_template.go` 的
// `xbpqTemplateFamilies` / `xbpqApplyTemplate`。
//
// 为什么需要：实测 334 份 csp_XBPQ 源里，55% 只写了「分类url+分类」就能正常
// 工作 —— 官方 XBPQ.jar 会按 分类url 的形态自动套用内置模板，补上
// 数组/标题/链接/图片/播放/搜索全套默认 pattern。没有这一层，那些源在
// 本引擎里会一条都抽不出来。
//
// 规则：命中家族**依次合并**（先命中的字段优先），已写字段一律不覆盖；幂等。
// 字段值以 `||` 串多个备选 pattern，由 `XbpqCut` 逐个尝试。

import 'package:tvbox/services/xbpq/xbpq_rule.dart';
import 'package:tvbox/services/xbpq/xbpq_util.dart';

class XbpqTemplateFamily {
  const XbpqTemplateFamily({
    required this.name,
    required this.match,
    required this.fields,
  });

  final String name;
  final RegExp match;
  final Map<String, String> fields;
}

class XbpqTemplate {
  XbpqTemplate._();

  /// 家族按「专用 → 通用」排序，全部命中项都会合并（不 break）。
  static final List<XbpqTemplateFamily> families = [
    // 苹果CMS新版 mxone 皮肤（/template/mxone/）：列表条目 div.module-item、
    // 多线路 div.module-list...tab-list。关键差异：线路容器与分集容器同锚点，
  // 分集是 <a> 连排（段内无 #），所以 播放列表 分隔符写 </a>。
    XbpqTemplateFamily(
      name: 'MacCMS新版mxone',
      match: RegExp(
        r'/index-(?:\{cateId\}|[0-9])[^/"?]*\.html',
        caseSensitive: false,
      ),
      fields: const {
        '数组': '<div class="module-item"&&<div class="module-item"'
            '||class="module-item"><div class="module-item-cover"&&</div></div>'
            '||<div class="module-item"&&</div></div>||<li&&</li>',
        '标题': 'title="&&"',
        '副标题': 'class="module-item-text">&&</div>',
        '图片': 'data-src="&&"||data-original="&&"',
        '链接': 'href="&&"',
        '播放数组': 'class="module-list module-player-list tab-list sort-list&&</div>',
        '线路数组': 'class="module-list module-player-list tab-list sort-list&&</div>',
        '播放列表': '</a>',
        '播放标题': '<span>&&</span>',
        '播放链接': 'href="&&"',
        '搜索数组': '<div class="module-search-item"&&<div class="video-info-main">',
        '搜索标题': '<h3>&&</h3>',
        '搜索链接': 'video-serial" href="&&"',
        '搜索图片': 'data-src="&&"',
      },
    ),

    // MacCMS 自带 API（/api.php/provide/vod/）：列表层是 JSON，用 j: 模式；
    // 详情/播放仍走 HTML 详情页。
    XbpqTemplateFamily(
      name: 'MacCMS接口(JSON)',
      match: RegExp(
        r'api\.php/provide/vod|/provide/vod/?|ac=videolist',
        caseSensitive: false,
      ),
      fields: const {
        '数组': 'j:list',
        '标题': 'j:vod_name',
        '图片': 'j:vod_pic',
        '副标题': 'j:vod_remarks',
        '链接': '/index.php/vod/detail/id/+j:vod_id+.html',
        '详情url': '/index.php/vod/detail/id/{id}.html',
        '搜索url': '{host}/index.php/vod/search.html?wd={wd}',
        '播放数组': '<ul class="stui-content__playlist&&</ul>'
            '||<ul class="myui-content__list&&</ul>',
        '播放列表': '<a',
        '播放标题': '>&&</a>||>&&<',
        '播放链接': 'href="&&"',
        '跳转播放链接': 'var player_*"url":"&&"',
      },
    ),

    // 苹果CMS/MacCMS 家族（stui / myui / hl / module 皮肤）。
    // 数组首个备选带 `<a ` 前缀：myui 的 <a> 由 class 起头，缺了 `<a` 段内会
    // 丢开标签；mxone poster-items 皮肤必须用 `<a &&</a>[包含:...]`，直接锚
    // module-poster-item 会把卡片截半。
    XbpqTemplateFamily(
      name: 'MacCMS',
      match: RegExp(
        r'/index\.php/(vod|art)/|/vod(show|type|play|detail)/'
        r'|/list/(?:\{cateId\}|[0-9])[^/"]*\.html|vod-(?:list|play)-id-',
        caseSensitive: false,
      ),
      fields: const {
        '数组': '<a class="myui-vodlist__thumb&&</a>'
            '||class="myui-vodlist__box&&</a>'
            '||class="stui-vodlist__thumb&&</a>'
            '||stui-vodlist__box">&&</div></div>'
            '||hl-item-thumb hl-lazy"&&</a>'
            '||<a &&</a>[包含:module-poster-item module-item]'
            '||<li class="col-md-6&&</li>||<li&&</li>',
        '标题': 'title="&&"||alt="&&"',
        '图片': 'data-original="&&"||data-src="&&"||src="&&"',
        '副标题': 'pic-text text-right">&&</span>||class="remark">&&<'
            '||module-item-text">&&</div>||class="module-item-note">&&</div>',
        '链接': 'href="&&"',
        '简介': 'detail-content" style=*>&&</span>'
            '||class="stui-content__detail&&</div>||简介：</em>&&'
            '||class="module-info-intro-content&&</div>',
        '播放数组': '<ul class="stui-content__playlist&&</ul>'
            '||<ul class="myui-content__list&&</ul>'
            '||id="hl-plays-list"&&</ul>'
            '||mod play-list&&</ul'
            '||class="play_box&&</div>'
            '||class="module-play-list-content&&</div>',
        '线路数组': 'class="module-play-list-content&&</div>',
        // 播放列表是**分集分隔符**（字面 Split），不是截取串：
        // 写 `<a&&</a>` 会切不中，整段塌成 1 集。
        '播放列表': '<a',
        '播放标题': '>&&</a>||>&&<||<span>&&</span>',
        '播放链接': 'href="&&"',
        '线路标题': '<h3 class="title">&&</h3>||<span class="title">&&</span>'
            '||play_tit&&</||data-name="&&"',
        // 聚类最高频跳转形态（含尾引号——单侧无尾锚会吃到页尾）。
        // var player_ 前缀不会误命中同页 var maccms 的 "url":"。
        '跳转播放链接': 'var player_*"url":"&&"||player_aaaa_*"url":"&&"',
        '搜索url': '{host}/index.php/vod/search.html?wd={wd}',
        '搜索数组': '<div class="module-card-item module-item&&<div class="module-card-item module-item'
            '||class="stui-vodlist__thumb&&</a>||<li&&</li>',
        '搜索标题': 'title="&&"||<strong>&&</strong>||alt="&&"',
        '搜索链接': 'href="&&"',
        '搜索图片': 'data-original="&&"||data-src="&&"',
      },
    ),

    // 短剧/路径式 CMS：/show/{id}-…html、/vs/、/type/{slug}/{pg}/、/fenlei/…
    // 这一族没有可靠通用默认，只给通用高频值。
    XbpqTemplateFamily(
      name: '路径式泛型',
      match: RegExp(
        r'/(show|vs|vshow|screen|list|type|category|fenlei)/(?:\{cateId\}|[0-9a-z])',
        caseSensitive: false,
      ),
      fields: const {
        '数组': 'class="stui-vodlist__thumb&&</a>||module-item&&</a>||<li&&</li>',
        '标题': 'title="&&"||alt="&&"',
        '图片': 'data-original="&&"||data-src="&&"||src="&&"',
        '副标题': 'pic-text text-right">&&</span>||module-item-text">&&</div>',
        '链接': 'href="&&"',
        '简介': 'detail-content" style=*>&&</span>||class="video-info&&</div>',
        '播放数组': '<ul class="stui-content__playlist&&</ul>'
            '||<ul class="myui-content__list&&</ul>'
            '||<ul class="content-list&&</ul>'
            '||class="module-play-list&&</div>',
        '播放列表': '<li',
        '播放标题': '>&&</a>||>&&<',
        '播放链接': 'href="&&"',
        '线路标题': '<h3 class="title">&&</h3>',
        '跳转播放链接': 'var player_*"url":"&&"',
      },
    ),

    // 通用高频兜底：任何有 分类url 的形态都命中。
    // 只补全局最稳的字段，绝不猜 数组/播放数组 这类站专属结构。
    XbpqTemplateFamily(
      name: '通用高频',
      match: RegExp('.'),
      fields: const {
        '标题': 'title="&&"||alt="&&"',
        '链接': 'href="&&"',
        '图片': 'data-original="&&"||data-src="&&"||src="&&"',
        '播放标题': '>&&</a>||>&&<',
        '播放链接': 'href="&&"',
      },
    ),
  ];

  /// 按 分类url 形态补齐缺失字段（不覆盖已写字段）。幂等。
  ///
  /// 直接改 `fields` / `order`，与 Go 的 `*xbpqRule` 指针语义一致。
  static void apply(Map<String, String> fields, List<String> order) {
    if ((fields['模板已套用'] ?? '').isNotEmpty) return;

    final category = _first(fields, const ['分类url', '分类Url']);
    if (category.isEmpty) return;

    final origin = XbpqUtil.hostOrigin(category);
    for (final family in families) {
      if (!family.match.hasMatch(category)) continue;
      for (final entry in family.fields.entries) {
        final key = XbpqRule.normalizeKey(entry.key);
        var value = entry.value;
        if (value.contains('{host}')) {
          if (origin.isEmpty) continue;
          value = value.replaceAll('{host}', origin);
        }
        if ((fields[key] ?? '').trim().isEmpty) {
          fields[key] = value;
          order.add(key);
        }
      }
      // 不 break：专用→通用依次合并，后面的家族只补还没被覆盖的字段。
    }
    fields['模板已套用'] = '1';
  }

  static String _first(Map<String, String> fields, List<String> names) {
    for (final name in names) {
      final value = fields[XbpqRule.normalizeKey(name)];
      if (value != null && value.isNotEmpty) return value;
    }
    return '';
  }
}
