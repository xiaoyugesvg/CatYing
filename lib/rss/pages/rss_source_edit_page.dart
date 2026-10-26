import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/rss/models/rss_source.dart';
import 'package:tvbox/rss/services/rss_store.dart';

/// 编辑 RSS 订阅源（含规则 / 请求头 / 分类）。
///
/// 用户 2026-10-20：「RSS 源能编辑修改导入的脚本吗？」—— 之前只能改名/分组，
/// 站点改版后旧规则一条都改不了，只能删了重导。这里把**规则字段全部开放**。
class RssSourceEditPage extends StatefulWidget {
  const RssSourceEditPage({super.key, required this.source});

  final RssSource source;

  @override
  State<RssSourceEditPage> createState() => _RssSourceEditPageState();
}

class _RssSourceEditPageState extends State<RssSourceEditPage> {
  late final TextEditingController _name =
      TextEditingController(text: widget.source.name);
  late final TextEditingController _url =
      TextEditingController(text: widget.source.url);
  late final TextEditingController _group =
      TextEditingController(text: widget.source.group);
  late final TextEditingController _sortUrl =
      TextEditingController(text: widget.source.sortUrl);
  late final TextEditingController _articles =
      TextEditingController(text: widget.source.ruleArticles ?? '');
  late final TextEditingController _title =
      TextEditingController(text: widget.source.ruleTitle ?? '');
  late final TextEditingController _link =
      TextEditingController(text: widget.source.ruleLink ?? '');
  late final TextEditingController _image =
      TextEditingController(text: widget.source.ruleImage ?? '');
  late final TextEditingController _pubDate =
      TextEditingController(text: widget.source.rulePubDate ?? '');
  late final TextEditingController _desc =
      TextEditingController(text: widget.source.ruleDescription ?? '');
  late final TextEditingController _content =
      TextEditingController(text: widget.source.ruleContent ?? '');
  late final TextEditingController _nextPage =
      TextEditingController(text: widget.source.ruleNextPage ?? '');
  late final TextEditingController _header =
      TextEditingController(text: widget.source.header);
  late final TextEditingController _jsLib =
      TextEditingController(text: widget.source.jsLib);
  late final TextEditingController _blacklist =
      TextEditingController(text: widget.source.contentBlacklist);

  late bool _enabled = widget.source.enabled;
  late bool _singleUrl = widget.source.singleUrl;
  late bool _loadWithBaseUrl = widget.source.loadWithBaseUrl;
  late bool _cookieJar = widget.source.enabledCookieJar;
  late bool _preload = widget.source.preload;
  late bool _cacheFirst = widget.source.cacheFirst;
  late int _articleStyle = widget.source.articleStyle;

  final List<TextEditingController> _all = [];

  @override
  void initState() {
    super.initState();
    _all.addAll([
      _name, _url, _group, _sortUrl, _articles, _title, _link, _image,
      _pubDate, _desc, _content, _nextPage, _header, _jsLib, _blacklist,
    ]);
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty || url.isEmpty) {
      AppToast.error('名称和地址不能为空');
      return;
    }
    // 用 toJson → 覆盖字段 → fromJson 复原：以后加字段也不会漏（id 会被保留）
    final json = widget.source.toJson()
      ..['name'] = name
      ..['url'] = url
      ..['group'] = _group.text.trim()
      ..['sortUrl'] = _sortUrl.text
      ..['ruleArticles'] = _articles.text
      ..['ruleTitle'] = _title.text
      ..['ruleLink'] = _link.text
      ..['ruleImage'] = _image.text
      ..['rulePubDate'] = _pubDate.text
      ..['ruleDescription'] = _desc.text
      ..['ruleContent'] = _content.text
      ..['ruleNextPage'] = _nextPage.text
      ..['header'] = _header.text
      ..['jsLib'] = _jsLib.text
      ..['contentBlacklist'] = _blacklist.text
      ..['enabled'] = _enabled
      ..['singleUrl'] = _singleUrl
      ..['loadWithBaseUrl'] = _loadWithBaseUrl
      ..['enabledCookieJar'] = _cookieJar
      ..['preload'] = _preload
      ..['cacheFirst'] = _cacheFirst
      ..['articleStyle'] = _articleStyle;
    final updated = RssSource.fromJson(json);
    if (updated == null) {
      AppToast.error('保存失败：名称或地址不合法');
      return;
    }
    await RssStore.instance.saveSource(updated);
    if (!mounted) return;
    AppToast.message('已保存「$name」');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '编辑订阅源',
      action: TextButton(
        onPressed: _save,
        child: const Text('保存'),
      ),
      children: [
        SettingsGroup(
          title: '基础',
          children: [
            _field('名称', _name, hint: '显示名称'),
            _field('地址', _url, hint: '站点或 RSS 地址', maxLines: 2),
            _field('分组', _group, hint: '可留空'),
          ],
        ),
        SettingsGroup(
          title: '列表规则',
          hint: '支持 Legado 规则：@css / @xpath / @json / @js，&& || 复合',
          children: [
            _field('列表项', _articles, hint: r'如 class.item 或 $.data.list[*]',
                maxLines: 3, mono: true),
            _field('标题', _title, hint: '如 tag.a@text', mono: true),
            _field('链接', _link, hint: '如 tag.a@href', mono: true),
            _field('封面', _image, hint: '如 tag.img@src', mono: true),
            _field('时间', _pubDate, hint: '可留空', mono: true),
            _field('简介', _desc, hint: '可留空', maxLines: 2, mono: true),
            _field('正文', _content, hint: '可留空（留空则抓文章页自动提取）',
                maxLines: 4, mono: true),
            _field('下一页', _nextPage, hint: '如 class.next@href', mono: true),
          ],
        ),
        SettingsGroup(
          title: '分类',
          hint: '每行 `名称::地址`；地址里可用 {{page}} 或整段 js 规则',
          children: [
            _field('分类列表', _sortUrl, maxLines: 6, mono: true),
          ],
        ),
        SettingsGroup(
          title: '请求',
          children: [
            _field('请求头', _header, hint: 'JSON，如 {"User-Agent":"..."}',
                maxLines: 4, mono: true),
            _field('jsLib', _jsLib, hint: '规则里用到的 JS 工具函数（可留空）',
                maxLines: 4, mono: true),
            _field('内容黑名单', _blacklist, hint: '正则或 URL 片段（可留空）',
                mono: true),
          ],
        ),
        SettingsGroup(
          title: '选项',
          children: [
            _switch('启用', _enabled, (v) => setState(() => _enabled = v)),
            _switch(
              '站点型（直接打开网页）',
              _singleUrl,
              (v) => setState(() => _singleUrl = v),
              hint: '开启后不解析列表，直接内嵌网页',
            ),
            _switch(
              '补全相对地址',
              _loadWithBaseUrl,
              (v) => setState(() => _loadWithBaseUrl = v),
            ),
            _switch(
              'Cookie 保存（登录态）',
              _cookieJar,
              (v) => setState(() => _cookieJar = v),
            ),
            _switch('预取首条正文', _preload,
                (v) => setState(() => _preload = v)),
            _switch('缓存优先', _cacheFirst,
                (v) => setState(() => _cacheFirst = v)),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '正文样式',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead + 0.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('自动')),
                      ButtonSegment(value: 1, label: Text('纯文本')),
                      ButtonSegment(value: 2, label: Text('富文本')),
                    ],
                    selected: {_articleStyle},
                    onSelectionChanged: (v) =>
                        setState(() => _articleStyle = v.first),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 30),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController ctrl, {
    String? hint,
    int maxLines = 1,
    bool mono = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: ctrl,
            maxLines: maxLines,
            minLines: 1,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontFootnote,
              fontFamily: mono ? 'monospace' : null,
              height: 1.35,
            ),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontFootnote,
              ),
              filled: true,
              fillColor: AppTheme.backgroundTertiary,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _switch(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead + 0.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (hint != null)
                  Text(
                    hint,
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
