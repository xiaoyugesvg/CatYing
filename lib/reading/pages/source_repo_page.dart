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
              _buildCloudCard(isDark),
              const SizedBox(height: 12),
              _buildManualImportCard(isDark),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '已注册源（${sources.length}）· 关闭后不在搜索页显示',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
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
  Widget _buildManualImportCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.add_link_rounded, size: 18, color: JellyTheme.primary),
              const SizedBox(width: 6),
              Text(
                '手动导入漫画源',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '粘贴漫画源 JSON（单个源对象 / 完整 sources.json / 数组都行）',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _showImportSheet,
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              label: const Text('粘贴导入'),
            ),
          ),
        ],
      ),
    );
  }

  /// 导入弹层：粘贴框 + 格式提示 + 导入按钮。
  ///
  /// 键盘避让用 viewInsets（和全项目其它弹窗一致）——
  /// 这个框要输入很长的 JSON，被键盘盖住会完全没法用。
  Future<void> _showImportSheet() async {
    final ctrl = TextEditingController();
    var error = '';
    var busy = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDarkNow() ? JellyTheme.cardDark : JellyTheme.cardLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Future<void> doImport() async {
            final text = ctrl.text.trim();
            if (text.isEmpty) {
              setSheet(() => error = '请先粘贴漫画源 JSON');
              return;
            }
            setSheet(() {
              busy = true;
              error = '';
            });
            final r = await _importJson(text);
            if (!ctx.mounted) return;
            if (r.ok) {
              Navigator.pop(ctx);
              _toast(r.message);
              if (mounted) setState(() {});
            } else {
              setSheet(() {
                busy = false;
                error = r.message;
              });
            }
          }

          return Padding(
            // 键盘避让
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
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
                          color: JellyTheme.textSecondary.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '导入漫画源',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isDarkNow() ? Colors.white : JellyTheme.textPrimaryLight,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '支持三种格式：\n'
                      '· 单个源 {"type":"config","config":{...}}\n'
                      '· 完整文件 {"version":1,"sources":[...]}\n'
                      '· 纯数组 [{...},{...}]\n'
                      'type=config 是通用网页源（提供 DOM 选择器）；'
                      'type=api 复用内置引擎。',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.5,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: ctrl,
                      maxLines: 7,
                      minLines: 4,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '在此粘贴漫画源 JSON…',
                        hintStyle: TextStyle(
                            fontSize: 13, color: JellyTheme.textSecondary),
                        filled: true,
                        fillColor: isDarkNow()
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.black.withValues(alpha: 0.04),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    if (error.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        error,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.redAccent),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () async {
                            final d = await Clipboard.getData('text/plain');
                            final s = d?.text;
                            if (s != null && s.isNotEmpty) {
                              ctrl.text = s;
                              setSheet(() => error = '');
                            }
                          },
                          icon: Icon(Icons.content_paste_rounded,
                              size: 16, color: JellyTheme.primary),
                          label: Text('粘贴剪贴板',
                              style: TextStyle(
                                  fontSize: 13, color: JellyTheme.primary)),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: busy ? null : doImport,
                          child: busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Text('导入'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    ctrl.dispose();
  }

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
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '填写云端 sources.json 地址，更新后覆盖本地源配置',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'https://example.com/sources.json',
              hintStyle: TextStyle(
                fontSize: 13,
                color: JellyTheme.textSecondary,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _busy ? null : _updateFromCloud,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download_rounded, size: 18),
              label: const Text('从云端更新'),
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
