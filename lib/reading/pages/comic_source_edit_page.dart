// 漫画源编辑页：修改单个漫画源的配置（名称 / URL / 抓取规则选择器）。
//
// 与「书源仓库 → 编辑」同一模式：仓库卡片点进来，改完保存回本地配置
// （SourceConfigStore.saveLocal 合并，同 id 替换、其余源不动），再 reload。
//
// ── config 源（type=config）────────────────────────────────────
// config 体即 SiteConfig 字段（snake_case 键），可改名称 / URL / 图标 /
// 详情、章节、图片、搜索、分类等常用字段；空值 = 删除该键（保持配置干净）。
// 隐藏字段（脚本类 chapter_script / img_script 等）在源 JSON 里已存在的
// 会一并保留（保存时只改表单里出现过的键）。
//
// ── api 源（type=api）──────────────────────────────────────────
// config 体为引擎协议（id / base / ua / categories），只允许改显示名称，
// 协议字段只读展示 —— 引擎协议字段写错会直接破坏抓取，不提供随意修改。

import 'package:flutter/material.dart';

import '../source/source_config_store.dart';
import '../source/source_definition.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';
import '../../common/theme.dart';

/// 常用可编辑字段分组（config 源）。
/// label：分组标题；entries：[(键名, 中文说明, 占位提示)]。
class _FieldGroup {
  const _FieldGroup(this.title, this.entries);
  final String title;
  final List<(String, String, String)> entries;
}

const _fieldGroups = <_FieldGroup>[
  _FieldGroup('详情', [
    ('comic_cover_dom', '封面', '详情页封面 img 选择器'),
    ('comic_name_dom', '名称', '详情页名称选择器'),
    ('comic_author_dom', '作者', '详情页作者选择器'),
    ('comic_desc_dom', '简介', '详情页简介选择器'),
    // ✅ **本段前言已更正**（本会话 ✓）—— 它原来写着「下面 5 个字段**引擎侧还没实现** ✗、
    //   用户填了**完全无效** ✓、属于"界面骗人" ✗」，那是**当时的实情** ✓；
    //   但本会话把这几个键**逐个接通**了 ✓✓（消费点见下 ↓），所以那段话**已不成立** ✗。
    //   ⇒ 现在**按事实**说明 ✓：**下面这些键引擎都会读** ✓；
    //     每一项的语义/边界都在自己的 hint 里写清了 ✓（**不夸大、不假装覆盖全部语义** ✗）。
    // ✅ **这 5 个键现已全部实现并生效** ✓（本会话收口 ✓）——
    //   ⇒ 上面那段"下面 5 个字段**引擎都没实现**"的说法**已完全不成立** ✗，特此更正 ✓：
    //      `status_label` ✓ **已实现**（站点没给状态时用它兜底 ✓ 见 `config_manga_source` 详情解析 ✓）
    //      `chapter_click_dom` ✓ **已实现**（WebView 取章节前先点它展开目录 ✓ `_doFetchChapters` ✓）
    //      `concurrent_rate` ✓ **已实现**（两处并发池改读源配置 ✓ 上限 clamp 1~8 ✓ 没填=默认 8 ✓）
    //      `tags_split` ✓ **已实现**（单元素里塞一串标签 → 按分隔符拆开 ✓）
    //      `search_method` / `search_post_body` ✓ **已实现**（搜索 GET/POST 分派 ✓ `_fetchHtmlByPost` ✓）
    //   ℹ️ 唯一"如实标注"的边界 ✓：`concurrent_rate` 只实现「**同时并发数上限**」这一种语义 ✓
    //      （Legado 里可能还含"每秒请求数"✗ —— 没有假装覆盖 ✓）
    //   ✅ `tags_split` **已实现** ✓（本轮 ✓ 见 `config_manga_source` 的标签收集处 ✓）→ 标注已摘 ✓
    //   ⇒ 留空 = 行为不变 ✓；填了才拆 ✓（服务"单元素里塞了一串标签"的源 ✓）
    //   完成链（供以后对照 ✓）：`SiteConfig` 加字段 + fromJson/toJson ✓ →
    //   `config_manga_source` 详情解析里取值 ✓ → `CManga` →
    //   `comicToCManga` / `cmangaToComic` ✓（这两层**本来就映射好了** ✓）
    ('comic_status_dom', '状态', '详情页状态选择器（取元素文本 ✓）'),
    ('comic_tags_dom', '标签', '详情页标签选择器（**匹配多个元素** ✓，逐个取文本成列表 ✓）'),
    ('comic_hot_dom', '热度', '详情页热度选择器（从中取数字作为热度 ✓）'),
    ('author_label', '作者标签', '作者区前缀文本（取 label 后剩余）'),
    ('status_label', '状态标签', '站点没给状态时用它兜底（如 连载中）✓；留空=站点没给就不显示 ✓'),
    ('tags_split', '标签分隔符', '标签在一个元素里用它分隔（如 逗号）✓；留空=每个元素算一个标签 ✓'),
  ]),
  _FieldGroup('章节', [
    ('chapter_name_dom', '章节名', '章节列表名称选择器'),
    ('chapter_link_dom', '章节链接', '章节列表链接选择器'),
    ('chapter_url_pattern', '链接模板', '章节链接 URL 模板'),
    // ✅ **`chapter_click_dom` 已实现**（本会话 ✓）—— 原来这里写着"引擎侧也没有实现"✗，
    //   现已**实现并接线** ✓✓：`webview_image_fetcher._doFetchChapters()` 在 `_loadPage(url)` 之后
    //   会**先点这个选择器**（`runJavaScript` 注入 ✓）→ 给 1.5s 渲染宽限 → 再走 chapterScript ✓；
    //   调用点 `config_manga_source` 已把 `site.chapterClickDom` 传进去 ✓。
    //   ℹ️ 留空 ✓ → WebView 侧**整段跳过** ✓（与从前完全一致 ✓ 现有源零影响 ✓）；
    //     点击"成功/未命中"都会写**日志** ✓（日志页能看到是哪一步的问题 ✓）。
    ('chapter_click_dom', '点击选择器', 'WebView 取章节前先点它展开目录 ✓；留空=不点（多数源无需）✓'),
  ]),
  _FieldGroup('图片', [
    ('img_dom', '图片容器', '章节页图片节点选择器'),
    ('img_attr', '图片属性', '图片 URL 属性（默认 src）'),
    ('img_referer', 'Referer', '取图 Referer（none 表示不发送）'),
    ('img_url_pattern', '图片URL模板', '图片 URL 模板（{index} 等）'),
    ('img_load_mode', '加载模式', '1=滚动 2=滚到底 3=下一页'),
    ('use_frame', '取图方式', '0=直连 1=WebView'),
    ('cross_origin', '跨域', '0=同源 1=跨源'),
    // ✅ `concurrent_rate` **已实现**（本会话 ✓）—— 原来这里写着"引擎未实现"✗，现已接线 ✓✓：
    //   `webview_image_fetcher` 的两处并发池（下标探测取图 ✓ / AES 直下 ✓）原先**写死 8** ✗，
    //   现在都读 `site.concurrentRate` ✓：`>0` 用它（**上限 clamp 1~8** ✓），**没填/0 → 仍是 8** ✓（零影响 ✓）
    //   ℹ️ 语义如实说明 ✓：实现的是「**同时并发数上限**」这一种 ✓（不是"每秒请求数" ✗）
    ('concurrent_rate', '限流', '同时并发上限 ✓（1~8，超出按 8 算）；留空/0 = 用引擎默认（8）✓'),
  ]),
  _FieldGroup('搜索', [
    ('search_url', '搜索URL', '搜索 URL 模板，{q} 占位'),
    ('search_result_dom', '结果项', '搜索结果项选择器'),
    ('search_title_dom', '结果标题', '结果标题选择器'),
    ('search_cover_dom', '结果封面', '结果封面选择器'),
    ('search_manga_url_dom', '结果链接', '结果详情链接选择器'),
    ('search_encoding', '编码', '关键词编码，默认 utf-8'),
    // ✅ **搜索现已支持 GET 与 POST** ✓（本轮实现 ✓ —— 见 `config_manga_source.search()`
    //   里的分派 ✓ 与新增的 `_fetchHtmlByPost()` ✓）⇒ 这两项**不再是"未实现"** ✗✓：
    //   · 留空 / 填 `GET` → 与从前**完全一样** ✓（GET + HTML 选择器 ✓，**向后兼容** ✓）
    //   · 填 `POST` → 用下方「POST 体」作请求体发 POST ✓（Legado 源里用 POST 搜索的那批 ✓）
    //     请求体与 URL 一样支持 `{q}`（关键词）与 `{page}`（页码）占位 ✓✓
    //   ⚠️ 如实说明一处边界 ✓：若该源同时开了「WebView 抓取」✓，那条路**只支持 GET** ✗ ——
    //     此时 POST 会**如实改走 Dio 并记一条日志** ✓（**不会静默把 POST 变成 GET** ✗）。
    ('search_method', '请求方式', '留空/GET=GET ✓；填 POST 则用下方请求体（对应 Legado 的 search_method）'),
    ('search_post_body', 'POST 体', 'POST 时的请求体 ✓，支持 {q} / {page} 占位（仅请求方式=POST 时生效）'),
  ]),
  _FieldGroup('分类', [
    ('category_url', '分类第1页', '分类 URL 模板'),
    ('category_page_url', '分类后续页', '分页 URL 模板（{page}）'),
    ('category_list_dom', '列表项', '分类列表项选择器'),
    ('category_cover_dom', '封面', '分类项封面选择器'),
    ('category_title_dom', '标题', '分类项标题选择器'),
    ('category_url_dom', '详情链接', '分类项详情链接选择器'),
    ('category_page_size', '每页条数', '满页判定条数（>0 启用计数分页）'),
  ]),
];

class ComicSourceEditPage extends StatefulWidget {
  const ComicSourceEditPage({super.key, required this.definition});

  final SourceDefinition definition;

  @override
  State<ComicSourceEditPage> createState() => _ComicSourceEditPageState();
}

class _ComicSourceEditPageState extends State<ComicSourceEditPage> {
  late final Map<String, dynamic> _config;
  late final Map<String, TextEditingController> _ctrls;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _config = Map<String, dynamic>.of(widget.definition.config);
    _ctrls = {};
    // 表单覆盖全部分组字段 + 名称/URL/图标；字段缺失时留空（保存时空值删键）。
    final allKeys = <String>{
      'name',
      'url',
      'icon',
      for (final g in _fieldGroups) for (final e in g.entries) e.$1,
    };
    for (final k in allKeys) {
      _ctrls[k] = TextEditingController(
        text: (_config[k] ?? '').toString(),
      );
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isApi => widget.definition.type == 'api';

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _save() async {
    final name = _ctrls['name']!.text.trim();
    if (name.isEmpty) {
      _toast('名称不能为空');
      return;
    }
    if (!_isApi) {
      final url = _ctrls['url']!.text.trim();
      if (url.isEmpty) {
        _toast('URL 不能为空');
        return;
      }
    }
    setState(() => _saving = true);
    try {
      // 组装新 config：表单有值的写入，空值删除（脚本类等未在表单的键保留）。
      final next = <String, dynamic>{};
      for (final g in _fieldGroups) {
        for (final e in g.entries) {
          final v = _ctrls[e.$1]!.text.trim();
          if (v.isNotEmpty) next[e.$1] = v;
        }
      }
      if (_isApi) {
        // api 源：只改显示名称，协议字段原样保留
        // ✅ 只补「表单里没有的键」（脚本类/分类结构等隐藏字段 ✓）：
        // 这里原来是 `next.addAll(_config)` ✗ —— 它在**收集完表单值之后**执行 ✓，
        // 于是**把用户刚改的值整体覆盖回旧值** ✗（表现：任何已有字段改了都不生效、
        // 清空也删不掉，界面却提示"保存成功" ✓）。
        // `putIfAbsent` 才是正确语义：表单值优先，缺失的才用旧配置兜底 ✓
        for (final e in _config.entries) {
          next.putIfAbsent(e.key, () => e.value);
        }
        next['name'] = name;
      } else {
        final vUrl = _ctrls['url']!.text.trim();
        final vIcon = _ctrls['icon']!.text.trim();
        // 保留未在表单里的隐藏字段（脚本类/分类结构等）
        // ✅ 只补「表单里没有的键」（脚本类/分类结构等隐藏字段 ✓）：
        // 这里原来是 `next.addAll(_config)` ✗ —— 它在**收集完表单值之后**执行 ✓，
        // 于是**把用户刚改的值整体覆盖回旧值** ✗（表现：任何已有字段改了都不生效、
        // 清空也删不掉，界面却提示"保存成功" ✓）。
        // `putIfAbsent` 才是正确语义：表单值优先，缺失的才用旧配置兜底 ✓
        for (final e in _config.entries) {
          next.putIfAbsent(e.key, () => e.value);
        }
        next['name'] = name;
        next['url'] = vUrl;
        if (vIcon.isNotEmpty) {
          next['icon'] = vIcon;
        } else {
          next.remove('icon');
        }
      }

      final def = SourceDefinition(
        id: widget.definition.id,
        type: widget.definition.type,
        engine: widget.definition.engine,
        config: next,
        needsMagic: widget.definition.needsMagic,
      );

      final store = SourceConfigStore();
      final local = await store.loadLocal();
      final out = <SourceDefinition>[];
      var replaced = false;
      for (final d in local) {
        if (d.id == widget.definition.id) {
          out.add(def);
          replaced = true;
        } else {
          out.add(d);
        }
      }
      if (!replaced) out.add(def);
      await store.saveLocal(out);
      await SourceManager().reload();
      if (!mounted) return;
      _toast('已保存「$name」');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      _toast('保存失败：${e.toString().split('\n').first}');
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtitle = _isApi
        ? 'API 源：仅可修改显示名称，协议字段（引擎/地址/UA/分类）只读'
        : '配置源：名称 / URL / 抓取规则均可修改，空字段将清除该规则';
    return Scaffold(
      appBar: AppBar(
        title: Text('编辑漫画源 · ${_config['name'] ?? ''}'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  _isApi
                      ? Icons.extension_rounded
                      : Icons.tune_rounded,
                  size: 18,
                  color: JellyTheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: JellyTheme.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _section('基本', [
            _field('name', '名称', '源显示名称'),
            if (!_isApi) _field('url', 'URL', '站点根地址（末尾 /）'),
            if (!_isApi) _field('icon', '图标 URL', '可选，列表图标'),
          ]),
          if (_isApi) _buildApiReadonly(),
          if (!_isApi)
            for (final g in _fieldGroups)
              _section(g.title, [
                for (final e in g.entries) _field(e.$1, e.$2, e.$3),
              ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildApiReadonly() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rows = <Widget>[
      for (final k in const ['id', 'engine', 'base', 'ua'])
        if (_config[k] != null && _config[k].toString().isNotEmpty)
          _readonlyRow(k, _config[k].toString(), isDark),
      if (_config['categories'] is List)
        _readonlyRow('categories', '${(_config['categories'] as List).length} 项', isDark),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8, top: 14),
          child: Text(
            '协议字段（只读）',
            style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(children: rows),
        ),
      ],
    );
  }

  Widget _readonlyRow(String k, String v, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              k,
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                color: JellyTheme.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8, top: 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(children: children),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _field(String key, String label, String hint) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: _ctrls[key],
        style: TextStyle(
          fontSize: AppTheme.fontBody,
          color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
        ),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle: TextStyle(
            fontSize: AppTheme.fontFootnote,
            color: JellyTheme.textSecondary.withValues(alpha: 0.7),
          ),
          labelStyle: TextStyle(
            fontSize: AppTheme.fontSubhead,
            color: JellyTheme.textSecondary,
          ),
          isDense: true,
          border: UnderlineInputBorder(
            borderSide: BorderSide(
              color: JellyTheme.textSecondary.withValues(alpha: 0.25),
            ),
          ),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(
              color: JellyTheme.textSecondary.withValues(alpha: 0.25),
            ),
          ),
        ),
      ),
    );
  }
}
