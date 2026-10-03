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
///
/// ── 这是你明确要求保留的功能 ──────────────────────────────────
/// 用户可以自己导入音源（文本粘贴 / 从文件 / 从 URL），
/// 支持两种形态（见 `ThirdPartySource`）：
///   · **模板法** `kind: keyword` —— 用 `{name}` `{artist}` `{id}` 占位符拼 URL
///   · **脚本法** `kind: script`  —— 整份 LX 脚本，能力更强
///
/// 导入解析器按 5 种格式依次尝试（JSON / 完整 LX 脚本 / JS 嵌 JSON /
/// 注释头 / 宽松脚本），异常宽容 —— 用户收集来的源格式五花八门。
class SourceManagerPage extends StatelessWidget {
  const SourceManagerPage({super.key});

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
          title: Text('音源管理',
              style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          actions: [
            IconButton(
              tooltip: 'LX 引擎自检',
              icon: Icon(Icons.verified_outlined, color: MusicTheme.tint),
              onPressed: () => runLxSelfTest(context),
            ),
            IconButton(
              tooltip: '导入音源',
              icon: Icon(Icons.add, color: MusicTheme.tint),
              onPressed: () => showImportSheet(context),
            ),
          ],
        ),
        body: ValueListenableBuilder<int>(
          valueListenable: store.revision,
          builder: (context, _, __) {
            final list = store.all;
            if (list.isEmpty) return _empty(context);
            return ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    '共 ${list.length} 个音源，${store.enabled.length} 个已启用。\n'
                    '播放时会优先用内置的公开接口；只有它拿不到音源时才尝试这里。',
                    style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontFootnote,
                        height: 1.5),
                  ),
                ),
                ...list.map((s) => _tile(context, store, s)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.extension_outlined,
                  size: 42, color: MusicTheme.secondary.withValues(alpha: 0.5)),
              const SizedBox(height: 14),
              Text('还没有导入音源',
                  style:
                      TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
              const SizedBox(height: 8),
              Text(
                '支持粘贴 JSON / LX 脚本，或从文件、网址导入。\n'
                '导入后可以单独启用/停用。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote,
                    height: 1.6),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: MusicTheme.tint,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => showImportSheet(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('导入音源'),
              ),
            ],
          ),
        ),
      );

  Widget _tile(BuildContext context, ThirdPartySourceStore store,
      ThirdPartySource s) {
    return ListTile(
      leading: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: MusicTheme.tint.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          s.isScript ? Icons.code_rounded : Icons.link_rounded,
          size: 17,
          color: MusicTheme.tint,
        ),
      ),
      title: Text(s.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w500)),
      subtitle: Text(
        '${s.isScript ? "LX 脚本" : "模板"} · 音质 ${s.quality}'
        '${s.headers.isEmpty ? "" : " · ${s.headers.length} 个请求头"}',
        style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: s.enabled,
            activeThumbColor: MusicTheme.tint,
            onChanged: (v) => store.setEnabled(s.id, v),
          ),
          IconButton(
            tooltip: '测试这个音源',
            icon: Icon(Icons.play_circle_outline,
                size: 19, color: MusicTheme.tint),
            onPressed: () => testSource(context, s),
          ),
          IconButton(
            icon: Icon(Icons.delete_outline,
                size: 19, color: MusicTheme.secondary),
            onPressed: () => _confirmDelete(context, store, s),
          ),
        ],
      ),
      onTap: () => _showDetail(context, s),
    );
  }

  Future<void> _confirmDelete(BuildContext context, ThirdPartySourceStore store,
      ThirdPartySource s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MusicTheme.card,
        title: Text('删除音源',
            style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
        content: Text('确定删除「${s.name}」？',
            style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontSubhead)),
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
                  style:
                      TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
            ),
            Expanded(
              child: Text(v,
                  style: TextStyle(
                      color: MusicTheme.label, fontSize: AppTheme.fontFootnote, height: 1.5)),
            ),
          ],
        ),
      );
}

/// 导入弹层：粘贴文本 / 从剪贴板 / 从网址
Future<void> showImportSheet(BuildContext context) async {
  final ctrl = TextEditingController();

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: MusicTheme.card,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => Padding(
      // 键盘避让：底部按 viewInsets 抬高，输入框不被挡
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(ctx).bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: MusicTheme.secondary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('导入音源',
                  style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                '支持：JSON 数组 / {"sources":[...]} / 完整 LX 脚本 / '
                '注释头（@name @template）/ 任意 JS 脚本',
                style: TextStyle(
                    color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote, height: 1.5),
              ),
              const SizedBox(height: 10),
              // ── ⚠️ 协议说明（可展开）──────────────────────────────
              //
              // 用户最容易踩的坑：拿一份**只注册了 `request`** 的 LX 脚本
              // 导进来，播放时报「脚本未实现 musicUrl（它提供：request）」——
              // 那不是网络问题，是**脚本没注册音乐地址这个 action**。
              //
              // LX 里 `request` 是"脚本自己要发 HTTP 请求"的**事件名**，
              // 而 `musicUrl` 才是**要被引擎调用的 action**；
              // `lx.request(url, options, cb)` 则是注入给脚本**调用**的
              // HTTP 客户端（不是要注册的事件）。三者很容易混。
              //
              // 把正确写法直接给出来，比让用户去猜有用得多。
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 6),
                  iconColor: MusicTheme.secondary,
                  collapsedIconColor: MusicTheme.secondary,
                  title: Text(
                    '脚本要写成什么样？（点开看示例）',
                    style: TextStyle(
                        color: MusicTheme.tint,
                        fontSize: AppTheme.fontFootnote,
                        fontWeight: FontWeight.w600),
                  ),
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: MusicTheme.fill,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: SelectableText(
                        "// ✅ 写法 1：lx.on\n"
                        "lx.on('musicUrl', async (info) => {\n"
                        "  return { url: 'https://cdn.example.com/' + info.musicInfo.id + '.mp3' };\n"
                        "});\n\n"
                        "// ✅ 写法 2：module.exports\n"
                        "module.exports = {\n"
                        "  musicUrl: async (info) => ({ url: 'https://…' })\n"
                        "};\n\n"
                        "// ❌ 只注册 request 会报「脚本未实现 musicUrl」\n"
                        "//    因为 request 是「脚本自己要发请求」的事件名，\n"
                        "//    而 musicUrl 才是引擎真正要调用的 action。",
                        style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontCaption,
                          height: 1.45,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                maxLines: 6,
                minLines: 3,
                style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontSubhead),
                cursorColor: MusicTheme.tint,
                decoration: InputDecoration(
                  hintText: '在此粘贴音源内容…',
                  hintStyle:
                      TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontSubhead),
                  // 透明底：去掉灰填充；补一条细边框保持粘贴区可辨识
                  filled: false,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: MusicTheme.divider,
                      width: 0.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      final d = await Clipboard.getData('text/plain');
                      final t = d?.text;
                      if (t != null && t.isNotEmpty) {
                        ctrl.text = t;
                      }
                    },
                    icon: Icon(Icons.content_paste_rounded,
                        size: 16, color: MusicTheme.tint),
                    label: Text('粘贴剪贴板',
                        style: TextStyle(
                            color: MusicTheme.tint, fontSize: AppTheme.fontSubhead)),
                  ),
                  const Spacer(),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: MusicTheme.tint,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () async {
                      final text = ctrl.text.trim();
                      if (text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请先粘贴音源内容')),
                        );
                        return;
                      }
                      try {
                        final n = await SourceImportParser.importIntoStore(text);
                        if (!context.mounted) return;
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(n > 0
                                ? '已导入 $n 个音源'
                                : '这些音源已存在，未重复导入'),
                          ),
                        );
                      } on SourceImportException catch (e) {
                        // 解析失败要给出**具体原因**，否则用户不知道该改什么
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('无法识别：${e.message}')),
                        );
                      }
                    },
                    child: const Text('导入'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  ctrl.dispose();
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
              color: r.ok ? MusicTheme.sage : Colors.redAccent, fontSize: AppTheme.fontHeadline)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('音源：${s.name}',
                style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
            Text('方式：${s.isScript ? "LX 脚本" : "模板"}',
                style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
            const SizedBox(height: 10),
            if (r.ok) ...[
              Text('解析到播放地址：',
                  style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontSubhead)),
              const SizedBox(height: 4),
              SelectableText(r.url,
                  style: TextStyle(color: MusicTheme.tint, fontSize: AppTheme.fontFootnote)),
            ] else
              Text(r.error.isEmpty ? '未返回播放地址' : r.error,
                  style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontSubhead)),
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
                style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote),
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
                              color: ok
                                  ? MusicTheme.sage
                                  : Colors.redAccent),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text('${m['name']}',
                                style: TextStyle(
                                    color: MusicTheme.label, fontSize: AppTheme.fontSubhead)),
                          ),
                          Text('${m['ms']}ms',
                              style: TextStyle(
                                  color: MusicTheme.secondary, fontSize: AppTheme.fontCaption)),
                        ],
                      ),
                      if (m['error'] != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 20, top: 2),
                          child: Text('${m['error']}',
                              style: TextStyle(
                                  color: MusicTheme.secondary, fontSize: AppTheme.fontCaption)),
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
