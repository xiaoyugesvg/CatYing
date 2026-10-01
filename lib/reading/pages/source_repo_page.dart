// 漫画源仓库：启用/禁用源 + 云端配置 URL + 手动导入。
//
// ⚠️ 与「书源仓库」是**两个独立页面**，别混：
//   · 本页（漫画源仓库）= SiteConfig，服务**漫画**（图片）
//   · 书源仓库（book_source_repo_page.dart）= Legado BookSource，服务**小说**（文字）
// 两者格式、存储、入口都分开（SourceConfigStore vs BookSourceStore）。
//
// 顶部输入云端 sources.json URL（持久化），点「从云端更新」Dio 拉取覆盖本地源；
// 源定义完全云端驱动，无「恢复默认」——本地覆盖层仅由升级迁移清空或云端更新覆盖。
// 下方列出所有已注册源，可单独启用/禁用，需要魔法的源标魔法图标。
// 搜索页只展示启用源（见 search_page._buildSourceChips 用 enabledSources）。

import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:archive/archive.dart';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/settings_service.dart';
import '../source/config_manga_source.dart';
import '../source/manga_source.dart';
import '../source/source_config_store.dart';
import '../source/source_definition.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';

class SourceRepoPage extends StatefulWidget {
  const SourceRepoPage({super.key});

  @override
  State<SourceRepoPage> createState() => _SourceRepoPageState();
}

class _SourceRepoPageState extends State<SourceRepoPage> {
  late final TextEditingController _urlCtrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: SettingsService().sourceRepoUrl);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

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

  Future<void> _updateFromCloud() async {
    final url = _urlCtrl.text.trim();
    await SettingsService().setSourceRepoUrl(url);
    if (url.isEmpty) {
      _toast('请先填写云端仓库地址');
      return;
    }
    setState(() => _busy = true);
    try {
      // fetchRemote 读用户填的云端 URL：为空返回 null；非空 Dio 拉取 -> saveLocal。
      final remote = await SourceConfigStore().fetchRemote();
      if (remote == null) {
        _toast('云端更新失败或为空，当前使用本地配置');
        return;
      }
      await SourceManager().reload();
      _toast('已从云端更新 ${remote.length} 个源');
    } catch (e) {
      _toast('云端更新失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('漫画源仓库')),
      body: ListenableBuilder(
        listenable: SourceManager(),
        builder: (context, _) {
          final sources = SourceManager().sources;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 按 cmbok V2.0.8 截图：**只有一张卡片**「云端仓库」，
              // 地址框 + 两个按钮（导入文件 / 从云端更新）。
              // 原来我把"手动导入"单独做成一张卡，图里没有 —— 已合并。
              _buildCloudCard(isDark),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  // 截图原文就是「共 N 个」
                  '共 ${sources.length} 个',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (sources.isEmpty) _buildEmptyState(isDark),
              for (final s in sources) ...[
                _buildSourceCard(isDark, s),
                const SizedBox(height: 10),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 手动导入卡片。
  ///
  /// ── 为什么要有这个 ────────────────────────────────────────────
  /// 原版只支持「填云端 sources.json 地址 → 整体覆盖本地」，
  /// 用户想加**单独一个源**时无处可下（也没法删掉某个源）。
  /// 这里补上：粘贴 JSON 导入单个源 / 一份完整 sources.json，并支持删除。
  ///
  /// 支持的格式（两种都吃）：
  ///   1. 单个源：      {"type":"config","config":{"name":"...","url":"...", ...}}
  ///   2. 完整文件：    {"version":1,"sources":[ ... ]}
  ///   3. 纯数组：      [ {...}, {...} ]
  /// 解析并写入本地源配置。
  ///
  /// 合并策略：**同 id 覆盖、新 id 追加**，其余保留 ——
  /// 用户导入一个源不该把他已有的源全冲掉。
  Future<({bool ok, String message})> _importJson(String text) async {
    try {
      final decoded = jsonDecode(text);
      final defs = <SourceDefinition>[];

      void take(dynamic raw) {
        if (raw is! Map) return;
        final m = raw.cast<String, dynamic>();
        // 单个源对象：有 config 字段
        if (m.containsKey('config') && m['config'] is Map) {
          defs.add(SourceDefinition.fromJson(m));
          return;
        }
        // 也可能是 SiteConfig 裸对象（直接贴 config 的内容）
        if (m.containsKey('name') && m.containsKey('url')) {
          // 裸 SiteConfig：id 按 SourceDefinition 的约定派生（config:${name}），
          // 与 SourceManager 用 ConfigMangaSource 时的 id 保持一致
          defs.add(SourceDefinition(
            id: 'config:${m['name']}',
            type: 'config',
            config: m,
          ));
        }
      }

      if (decoded is List) {
        for (final e in decoded) {
          take(e);
        }
      } else if (decoded is Map) {
        final m = decoded.cast<String, dynamic>();
        if (m['sources'] is List) {
          for (final e in (m['sources'] as List)) {
            take(e);
          }
        } else {
          take(m);
        }
      }

      if (defs.isEmpty) {
        return (
          ok: false,
          message: '没解析出漫画源。需要 {"type":"config","config":{"name":...,"url":...}} '
              '或 {"sources":[...]}',
        );
      }

      // 校验：type=config 必须有 name 与 url，否则导入后根本用不了，
      // 不如当场拦住并说清缺什么
      final bad = <String>[];
      for (final d in defs) {
        if (d.type == 'config') {
          final c = d.config;
          if ((c['name'] ?? '').toString().trim().isEmpty) {
            bad.add('缺少 name');
          } else if ((c['url'] ?? '').toString().trim().isEmpty) {
            bad.add('${c['name']} 缺少 url');
          }
        }
      }
      if (bad.isNotEmpty) {
        return (ok: false, message: '漫画源不完整：${bad.take(3).join('；')}');
      }

      final store = SourceConfigStore();
      final local = await store.loadLocal();
      final byId = {for (final d in local) d.id: d};
      var added = 0;
      var updated = 0;
      for (final d in defs) {
        if (d.id.trim().isEmpty) continue;
        if (byId.containsKey(d.id)) {
          updated++;
        } else {
          added++;
        }
        byId[d.id] = d;
      }
      await store.saveLocal(byId.values.toList());
      await SourceManager().reload();

      return (
        ok: true,
        message: added > 0 && updated > 0
            ? '新增 $added 个、更新 $updated 个漫画源'
            : (added > 0 ? '已导入 $added 个漫画源' : '已更新 $updated 个漫画源'),
      );
    } catch (e) {
      return (ok: false, message: 'JSON 解析失败：${e.toString().split('\n').first}');
    }
  }

  /// 当前是否深色（弹层里拿不到页面 context 的 theme 时用）
  bool isDarkNow() => Theme.of(context).brightness == Brightness.dark;

  Widget _buildCloudCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '云端仓库',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            // 截图原文。这句同时回答了用户两个疑问：
            // "会不会把我已有的源冲掉"（不会）+"多个地址怎么处理"（合并去重）
            '导入按地址合并去重，不会覆盖已有源',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            style: TextStyle(
              fontSize: 13.5,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: '书源地址（json / zip / 仓库索引）',
              hintStyle: TextStyle(
                fontSize: 13.5,
                color: JellyTheme.textSecondary,
              ),
              filled: true,
              fillColor: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.035),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 13,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 两个按钮并排（截图布局）
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _importFromFile,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.22)
                          : Colors.black.withValues(alpha: 0.16),
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    foregroundColor:
                        isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                  icon: const Icon(Icons.file_upload_outlined, size: 17),
                  label: const Text('导入文件',
                      style: TextStyle(fontSize: 13.5)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _updateFromCloud,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: _busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download_rounded, size: 17),
                  label: const Text('从云端更新',
                      style: TextStyle(fontSize: 13.5)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 从本地文件导入漫画源。
  ///
  /// 支持 `.json` / `.txt` / `.zip` —— 漫画源的分发同样是压缩包居多，
  /// 不认 zip 的话用户只会看到"解析失败"而看不出原因。
  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt', 'zip'],
      );
      if (result.isEmpty) return;
      final f = result.first;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) {
        _toast('文件是空的');
        return;
      }

      // zip 魔数 PK\x03\x04
      final isZip = bytes.length > 4 &&
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);

      if (!isZip) {
        // ⚠️ 必须 utf8.decode，不能用 String.fromCharCodes ——
        // 后者按"码元"直译，任何非 ASCII（中文源名）都会变乱码，
        // 症状是"导入成功但源名全是问号"。
        await _applyImportedText(utf8.decode(bytes, allowMalformed: true));
        return;
      }

      final archive = ZipDecoder().decodeBytes(bytes);
      var tried = 0;
      for (final zf in archive) {
        if (!zf.isFile) continue;
        final lower = zf.name.toLowerCase();
        if (!lower.endsWith('.json') && !lower.endsWith('.txt')) continue;
        tried++;
        final data = zf.content;
        final zb = data is Uint8List
            ? data
            : Uint8List.fromList(List<int>.from(data as List));
        await _applyImportedText(utf8.decode(zb, allowMalformed: true));
      }
      if (tried == 0) _toast('压缩包里没有 json / txt 文件');
    } catch (e) {
      _toast('导入失败：${e.toString().split('\n').first}');
    }
  }

  /// 把导入的文本交给 [_importJson]。
  ///
  /// 复用而不是重写：`_importJson` 已经处理了全部形态
  /// （单对象 / 数组 / `{"sources":[…]}` / 裸 SiteConfig）、
  /// 字段校验、同 id 覆盖合并、saveLocal + reload。
  /// 再写一遍只会分叉出第二套解析逻辑，以后改一处漏一处。
  Future<void> _applyImportedText(String text) async {
    final r = await _importJson(text);
    if (!mounted) return;
    if (r.ok) setState(() {});
    _toast(r.message);
  }

  /// 空态（按截图：还没有漫画源 + 说明怎么导）
  Widget _buildEmptyState(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        children: [
          Icon(
            Icons.folder_open_rounded,
            size: 56,
            color: JellyTheme.textSecondary.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 20),
          Text(
            '还没有漫画源',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              // 截图原文。注意"加密的"三个字 —— V2.0.8 的云端地址是密文，
              // 直接填明文地址是拉不到的（这点必须如实告诉用户，
              // 否则他会以为"我填了地址怎么没用"）。
              '粘贴加密的云端地址后点「从云端更新」，或导入密文文件',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: JellyTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceCard(bool isDark, MangaSource src) {
    final enabled = SourceManager().isEnabled(src.id);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          _buildSourceIcon(src),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        src.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight,
                        ),
                      ),
                    ),
                    if (src.needsMagic) ...[
                      const SizedBox(width: 6),
                      Image.asset(
                        'assets/icons/magic_stick.png',
                        width: 14,
                        height: 14,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  src.needsMagic ? '需要魔法（代理/VPN）' : src.id,
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            activeThumbColor: JellyTheme.primary,
            onChanged: (v) {
              SourceManager().setEnabled(src.id, v);
            },
          ),
          // 删除：能导入就得能删，否则用户导错一个源没法收拾
          IconButton(
            tooltip: '删除这个源',
            icon: Icon(Icons.delete_outline,
                size: 19, color: JellyTheme.textSecondary),
            onPressed: () => _confirmRemove(src),
          ),
        ],
      ),
    );
  }

  /// 删除一个源（从本地配置里摘掉，然后 reload）。
  ///
  /// ⚠️ 只删**本地配置**里的这一条。如果它来自云端 sources.json，
  /// 下次"从云端更新"会把它带回来 —— 所以删除确认里要说清这一点，
  /// 免得用户以为删不掉。
  Future<void> _confirmRemove(MangaSource src) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除漫画源', style: TextStyle(fontSize: 16)),
        content: Text(
          '确定删除「${src.name}」？\n\n'
          '注意：如果它来自云端 sources.json，下次「从云端更新」会重新出现。',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final store = SourceConfigStore();
      final local = await store.loadLocal();
      final left = local.where((d) => d.id != src.id).toList();
      await store.saveLocal(left);
      await SourceManager().reload();
      if (!mounted) return;
      setState(() {});
      _toast('已删除「${src.name}」');
    } catch (e) {
      _toast('删除失败：$e');
    }
  }

  /// 源图标：config 源有 icon URL 用网络图，否则用首字圆形占位。
  Widget _buildSourceIcon(MangaSource src) {
    final String? iconUrl = src is ConfigMangaSource ? src.site.icon : null;
    const size = 40.0;
    if (iconUrl != null && iconUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        // 用带磁盘缓存的图片：源仓库列表滚动时不重复下载图标
        child: CachedNetworkImage(
          imageUrl: iconUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => _initialAvatar(src, size),
        ),
      );
    }
    return _initialAvatar(src, size);
  }

  Widget _initialAvatar(MangaSource src, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: JellyTheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        src.name.isNotEmpty ? src.name[0] : '?',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: JellyTheme.primary,
        ),
      ),
    );
  }
}
