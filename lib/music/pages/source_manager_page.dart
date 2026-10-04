import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/third_party_source.dart';
import '../models/models.dart';
import '../services/music_api.dart';
import '../services/source_import_parser.dart';
import '../services/unblock_service.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';

/// 音源管理页 —— 移植自 Beans 的 `ThirdPartySourceManagerSheet.swift`。
/// 界面样式对齐洛雪（LX Music）"自定义音源"设置页（参考图 IMG_8538）：
///   标题「自定义音源」+ 右上角「完成」；
///   导入区内嵌三 tab（文本 / 链接 / 文件）+「识别并导入」按钮；
///   音源列表 = 名称 / 类型·音质标签 / 描述 + 编辑·排序·删除 + 数量角标。
///
/// ── 功能不变 ──────────────────────────────────────────────────
/// 用户可以自己导入音源（文本粘贴 / 从文件 / 从 URL），
/// 支持两种形态（见 `ThirdPartySource`）：
///   · **模板法** `kind: keyword` —— 用 `{name}` `{artist}` `{id}` 占位符拼 URL
///   · **脚本法** `kind: script`  —— 整份 LX 脚本，能力更强
/// 导入解析器按 5 种格式依次尝试（JSON / 完整 LX 脚本 / JS 嵌 JSON /
/// 注释头 / 宽松脚本），异常宽容 —— 用户收集来的源格式五花八门。
class SourceManagerPage extends StatefulWidget {
  const SourceManagerPage({super.key});

  @override
  State<SourceManagerPage> createState() => _SourceManagerPageState();
}

class _SourceManagerPageState extends State<SourceManagerPage> {
  /// 导入区当前 tab：0=文本，1=链接，2=文件
  int _tab = 0;
  final _textCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  String? _pickedName;
  String? _pickedContent;
  bool _busy = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = ThirdPartySourceStore.instance;
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text('自定义音源',
              style:
                  TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          actions: [
            IconButton(
              tooltip: 'LX 引擎自检',
              icon: Icon(Icons.verified_outlined, color: MusicTheme.tint),
              onPressed: () => runLxSelfTest(context),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('完成',
                  style: TextStyle(
                      color: MusicTheme.tint,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        body: ValueListenableBuilder<int>(
          valueListenable: store.revision,
          builder: (context, _, __) {
            final list = store.all;
            return ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                _intro(),
                _importCard(context),
                _listHeader(list.length),
                if (list.isEmpty)
                  _emptyHint()
                else
                  ...list.map((s) => _tile(context, store, s)),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── 顶部说明（对齐参考图两行说明）────────────────────────────
  Widget _intro() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '支持本地文件、远程URL和粘贴文本。',
              style: TextStyle(
                  color: MusicTheme.secondary, fontSize: AppTheme.fontSubhead),
            ),
            const SizedBox(height: 2),
            Text(
              '支持LX User API的JSON、JS、本地文件与在线URL；在线导入后会保存本地副本。',
              style: TextStyle(
                  color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote),
            ),
          ],
        ),
      );

  // ── 导入区（内嵌卡片：文本 / 链接 / 文件 + 识别并导入）────────
  Widget _importCard(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: MusicTheme.label.withValues(alpha: 0.06), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('导入音源',
              style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          _segmented(),
          const SizedBox(height: 12),
          if (_tab == 0)
            TextField(
              controller: _textCtrl,
              maxLines: 6,
              minLines: 3,
              style:
                  TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontSubhead),
              cursorColor: MusicTheme.tint,
              decoration: InputDecoration(
                hintText: '粘贴JSON/配置/脚本内容',
                hintStyle:
                    TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontSubhead),
                filled: false,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: MusicTheme.divider, width: 0.5),
                ),
              ),
            )
          else if (_tab == 1)
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              style:
                  TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontSubhead),
              cursorColor: MusicTheme.tint,
              decoration: InputDecoration(
                hintText: 'https://…',
                hintStyle:
                    TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontSubhead),
                filled: false,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: MusicTheme.divider, width: 0.5),
                ),
              ),
            )
          else
            _fileRow(context),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: MusicTheme.tint,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _busy ? null : () => _import(context),
              child: Text(_busy ? '导入中…' : '识别并导入'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '支持JSON数组、LX User API导出JSON、JS脚本、`SERVER_SCRIPT_CONFIG`片段，以及`@name`/`@template`头部格式。',
            style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontCaption,
                height: 1.5),
          ),
        ],
      ),
    );
  }

  /// 文本 / 链接 / 文件 三 tab（自绘分段，选中主题色）
  Widget _segmented() {
    const labels = ['文本', '链接', '文件'];
    return Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: MusicTheme.fill,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: List.generate(3, (i) {
          final selected = i == _tab;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _tab = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? MusicTheme.tint : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(labels[i],
                    style: TextStyle(
                      color: selected ? Colors.white : MusicTheme.secondary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    )),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _fileRow(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _pickFile,
      child: Container(
        width: double.infinity,
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: MusicTheme.divider, width: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.insert_drive_file_outlined,
                size: 20, color: MusicTheme.tint),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _pickedName ?? '点击选择本地音源文件（JSON / JS）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: _pickedName == null
                        ? MusicTheme.secondary
                        : MusicTheme.label,
                    fontSize: AppTheme.fontSubhead),
              ),
            ),
            Icon(Icons.folder_open_rounded,
                size: 18, color: MusicTheme.secondary),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFile() async {
    try {
      // file_picker 13：pickFiles 是静态方法，直接返回 List<PlatformFile>
      final res = await FilePicker.pickFiles(type: FileType.any);
      if (res.isEmpty) return;
      final f = res.first;
      if (f.path == null) return;
      final content = await File(f.path!).readAsString();
      if (!mounted) return;
      setState(() {
        _pickedName = f.name;
        _pickedContent = content;
      });
    } catch (e) {
      _toast(context, '读取文件失败：$e');
    }
  }

  Future<void> _import(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      var n = 0;
      if (_tab == 0) {
        final text = _textCtrl.text.trim();
        if (text.isEmpty) {
          _toast(context, '请先粘贴音源内容');
          return;
        }
        n = await SourceImportParser.importIntoStore(text);
      } else if (_tab == 1) {
        final url = _urlCtrl.text.trim();
        if (url.isEmpty) {
          _toast(context, '请输入音源链接');
          return;
        }
        // importIntoStore 内部会识别 URL 并自动下载解析（保存本地副本）
        n = await SourceImportParser.importIntoStore(url, fallbackName: url);
      } else {
        if (_pickedContent == null) {
          _toast(context, '请先选择文件');
          return;
        }
        n = await SourceImportParser.importIntoStore(_pickedContent!);
      }
      if (!mounted) return;
      _toast(context, n > 0 ? '已导入 $n 个音源' : '这些音源已存在，未重复导入');
    } on SourceImportException catch (e) {
      if (!mounted) return;
      _toast(context, '无法识别：${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast(context, '导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── 音源列表标题行 + 数量角标 ────────────────────────────────
  Widget _listHeader(int count) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Row(
          children: [
            Text('音源列表',
                style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('$count',
                style: TextStyle(
                    color: MusicTheme.tint,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _emptyHint() => Padding(
        padding: const EdgeInsets.fromLTRB(40, 30, 40, 10),
        child: Text(
          '还没有导入音源。\n在上方粘贴 / 链接 / 文件导入后，播放时内置接口拿不到地址会自动尝试这里。',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: MusicTheme.secondary,
              fontSize: AppTheme.fontFootnote,
              height: 1.6),
        ),
      );

  // ── 音源条目（对齐参考图：名称 / 标签 / 描述 + 编辑·排序·删除）──
  Widget _tile(BuildContext context, ThirdPartySourceStore store,
      ThirdPartySource s) {
    final tagText =
        '${s.isScript ? "脚本" : "KEYWORD"}·${s.quality}${s.isScript ? "" : "·${s.urlPath}"}';
    final desc = s.isScript
        ? 'LX 脚本 · ${(s.script ?? '').length} 字符'
        : (s.template.isEmpty ? '（无模板）' : s.template);
    final descExtra = s.headers.isEmpty ? '' : ' · ${s.headers.length} 个请求头';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 4),
      decoration: BoxDecoration(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: MusicTheme.label.withValues(alpha: 0.06), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: MusicTheme.label,
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    _tag(tagText),
                    const SizedBox(height: 4),
                    Text('$desc$descExtra',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: MusicTheme.secondary,
                            fontSize: AppTheme.fontFootnote)),
                  ],
                ),
              ),
              Switch(
                value: s.enabled,
                activeThumbColor: MusicTheme.tint,
                onChanged: (v) => store.setEnabled(s.id, v),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _action(Icons.play_circle_outline, '测试',
                  () => testSource(context, s)),
              _action(Icons.edit_outlined, '编辑',
                  () => _showDetail(context, s)),
              _action(Icons.swap_vert, '排序',
                  () => _sortMenu(context, store, s)),
              _action(Icons.delete_outline, '删除',
                  () => _confirmDelete(context, store, s)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tag(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: MusicTheme.tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: TextStyle(
                color: MusicTheme.tint,
                fontSize: AppTheme.fontCaption,
                fontWeight: FontWeight.w600)),
      );

  Widget _action(IconData icon, String label, VoidCallback onTap) =>
      TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: MusicTheme.secondary,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label,
            style: TextStyle(
                color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
      );

  Future<void> _sortMenu(BuildContext context,
      ThirdPartySourceStore store, ThirdPartySource s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MusicTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.arrow_upward, color: MusicTheme.tint),
              title: Text('上移',
                  style: TextStyle(
                      color: MusicTheme.label, fontSize: AppTheme.fontSubhead)),
              onTap: () => Navigator.pop(ctx, 'up'),
            ),
            ListTile(
              leading: Icon(Icons.arrow_downward, color: MusicTheme.tint),
              title: Text('下移',
                  style: TextStyle(
                      color: MusicTheme.label, fontSize: AppTheme.fontSubhead)),
              onTap: () => Navigator.pop(ctx, 'down'),
            ),
          ],
        ),
      ),
    );
    if (action == 'up') await store.move(s.id, -1);
    if (action == 'down') await store.move(s.id, 1);
  }

  Future<void> _confirmDelete(BuildContext context, ThirdPartySourceStore store,
      ThirdPartySource s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MusicTheme.card,
        title: Text('删除音源',
            style:
                TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
        content: Text('确定删除「${s.name}」？',
            style: TextStyle(
                color: MusicTheme.secondary, fontSize: AppTheme.fontSubhead)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) await store.remove(s.id);
  }

  void _showDetail(BuildContext context, ThirdPartySource s) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: MusicTheme.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.name,
                  style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              _kv('类型', s.isScript ? 'LX 脚本' : '模板法'),
              _kv('音质', s.quality),
              if (!s.isScript) ...[
                _kv('模板', s.template),
                _kv('取值路径', s.urlPath),
              ],
              if (s.isScript)
                _kv('脚本长度', '${(s.script ?? '').length} 字符'),
              if (s.headers.isNotEmpty)
                _kv('请求头',
                    s.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n')),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(
                      text: const JsonEncoderShim().encode(s.toJson()),
                    ));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制音源配置')),
                    );
                  },
                  child: const Text('复制配置'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 66,
              child: Text(k,
                  style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontFootnote)),
            ),
            Expanded(
              child: Text(v,
                  style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontFootnote,
                      height: 1.5)),
            ),
          ],
        ),
      );
}

/// 极简 JSON 编码（避免为了一个小功能再引依赖；只处理本模块的数据结构）
class JsonEncoderShim {
  const JsonEncoderShim();
  String encode(Object? o) {
    final sb = StringBuffer();
    _w(sb, o);
    return sb.toString();
  }

  void _w(StringBuffer sb, Object? o) {
    if (o == null) {
      sb.write('null');
    } else if (o is String) {
      sb.write('"${o.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"');
    } else if (o is num || o is bool) {
      sb.write(o);
    } else if (o is Map) {
      sb.write('{');
      var first = true;
      o.forEach((k, v) {
        if (!first) sb.write(',');
        first = false;
        _w(sb, k.toString());
        sb.write(':');
        _w(sb, v);
      });
      sb.write('}');
    } else if (o is List) {
      sb.write('[');
      for (var i = 0; i < o.length; i++) {
        if (i > 0) sb.write(',');
        _w(sb, o[i]);
      }
      sb.write(']');
    } else {
      _w(sb, o.toString());
    }
  }
}

/// 测试单个音源：用一首固定的歌去解析，把结果（成功地址 / 失败原因）显示出来。
///
/// 为什么用固定测试曲：用户需要判断"是音源坏了还是这首歌找不到"，
/// 固定输入才能横向比较不同音源。用一首无版权争议的常见曲目。
Future<void> testSource(BuildContext context, ThirdPartySource s) async {
  const probe = Song(
    id: 347230,
    name: '海阔天空',
    artists: 'Beyond',
    album: '乐与怒',
  );

  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(
    content: Text('正在测试「${s.name}」…'),
    duration: const Duration(seconds: 1),
  ));

  final r = await UnblockService.instance.testOne(s, probe);
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: MusicTheme.card,
      title: Text(r.ok ? '音源可用' : '音源不可用',
          style: TextStyle(
              color: r.ok ? MusicTheme.sage : Colors.redAccent,
              fontSize: AppTheme.fontHeadline)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('音源：${s.name}',
                style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote)),
            Text('方式：${s.isScript ? "LX 脚本" : "模板"}',
                style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote)),
            const SizedBox(height: 10),
            if (r.ok) ...[
              Text('解析到播放地址：',
                  style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontSubhead)),
              const SizedBox(height: 4),
              SelectableText(r.url,
                  style: TextStyle(
                      color: MusicTheme.tint,
                      fontSize: AppTheme.fontFootnote)),
            ] else
              Text(r.error.isEmpty ? '未返回播放地址' : r.error,
                  style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontSubhead)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
        if (!r.ok)
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // 失败时把配置摊开，方便用户自己比对哪里配错了
              Clipboard.setData(ClipboardData(
                text: const JsonEncoderShim().encode(s.toJson()),
              ));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制该音源配置，便于排查')),
              );
            },
            child: const Text('复制配置'),
          ),
      ],
    ),
  );
}

/// LX 引擎自检：在**真机上**验证沙箱与超时真的生效。
///
/// 这一步很有必要：LX 脚本是用户导入的任意 JS，最坏情况是死循环。
/// Node 与 App 同进程，事件循环被占住就会**整个 App 卡死**。
/// 这个按钮会跑一段"故意死循环"的脚本，用 8 秒超时把它中断 ——
/// 你能亲眼确认 App 没卡住。
Future<void> runLxSelfTest(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(
    content: Text('正在自检（含一段死循环，约 8 秒）…'),
    duration: Duration(seconds: 1),
  ));

  final r = await MusicApi.instance.lxSelfTest();
  if (!context.mounted) return;

  final cases = (r['cases'] as List?) ?? const [];
  final info = (r['info'] as Map?) ?? const {};

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: MusicTheme.card,
      title: Text(
        r['allPass'] == true ? 'LX 引擎自检通过' : 'LX 引擎自检有问题',
        style: TextStyle(
            color: r['allPass'] == true ? MusicTheme.sage : Colors.redAccent,
            fontSize: AppTheme.fontHeadline),
      ),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '超时 ${info['timeoutMs']}ms · '
                '脚本上限 ${asInt(info['maxScriptChars']) ~/ 1024}KB · '
                '沙箱已开',
                style: TextStyle(
                    color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote),
              ),
              const SizedBox(height: 10),
              ...cases.map((c) {
                final m = (c as Map).cast<String, dynamic>();
                final ok = m['pass'] == true;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(ok ? Icons.check_circle : Icons.cancel,
                              size: 14,
                              color: ok ? MusicTheme.sage : Colors.redAccent),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text('${m['name']}',
                                style: TextStyle(
                                    color: MusicTheme.label,
                                    fontSize: AppTheme.fontSubhead)),
                          ),
                          Text('${m['ms']}ms',
                              style: TextStyle(
                                  color: MusicTheme.secondary,
                                  fontSize: AppTheme.fontCaption)),
                        ],
                      ),
                      if (m['error'] != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 20, top: 2),
                          child: Text('${m['error']}',
                              style: TextStyle(
                                  color: MusicTheme.secondary,
                                  fontSize: AppTheme.fontCaption)),
                        ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
