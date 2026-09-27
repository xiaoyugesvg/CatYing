import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/live_service.dart';

/// 设置 → 直播：直播源管理 + 全局 EPG + 屏蔽分类
class LiveSettingsPage extends StatefulWidget {
  const LiveSettingsPage({super.key});

  @override
  State<LiveSettingsPage> createState() => _LiveSettingsPageState();
}

class _LiveSettingsPageState extends State<LiveSettingsPage> {
  final _epgCtrl = TextEditingController();
  final _blocked = <String>{}.obs;

  @override
  void initState() {
    super.initState();
    _epgCtrl.text = '';
  }

  @override
  void dispose() {
    _epgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: AppTheme.accentColor, size: 20),
          onPressed: () => Get.back(),
        ),
        title: const Text('直播设置',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          const Text('直播源管理',
              style: TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Obx(() {
              final groups = LiveService.instance.groups;
              final items = groups.isEmpty
                  ? <Widget>[
                      const _EmptyRow(),
                    ]
                  : [
                      for (final g in groups) _sourceTile(g.name),
                      _addTile(),
                    ];
              return Column(children: items);
            }),
          ),
          const SizedBox(height: 24),
          const Text('全局 EPG 地址',
              style: TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '直播源未自带 EPG 时使用，如 https://example.com/epg.xml.gz',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _epgCtrl,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.08),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          hintText: 'https://...',
                          hintStyle: const TextStyle(
                              color: Colors.white24, fontSize: 13),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accentColor,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 14),
                      ),
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('EPG 地址已保存')),
                        );
                      },
                      child: const Text('保存',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text('屏蔽分类',
              style: TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Obx(() {
              final groups = LiveService.instance.groups;
              return Column(
                children: [
                  if (groups.isEmpty)
                    const _EmptyRow()
                  else
                    for (final g in groups)
                      CheckboxListTile(
                        value: !_blocked.contains(g.name),
                        onChanged: (v) {
                          if (v == true) {
                            _blocked.remove(g.name);
                          } else {
                            _blocked.add(g.name);
                          }
                        },
                        title: Text(g.name,
                            style:
                                const TextStyle(color: Colors.white70, fontSize: 14)),
                        subtitle: Text('${g.channels.length} 个频道',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11)),
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: AppTheme.accentColor,
                      ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      '关闭后隐藏对应分类的频道',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _sourceTile(String name) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppTheme.accentColor.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.live_tv, color: AppTheme.accentColor, size: 20),
      ),
      title: Text(name,
          style:
              const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
      subtitle: const Text('已加载',
          style: TextStyle(color: Colors.white38, fontSize: 12)),
      trailing: PopupMenuButton<String>(
        color: const Color(0xFF2A2A2E),
        icon: const Icon(Icons.more_vert, color: Colors.white54),
        onSelected: (v) {
          if (v == 'refresh') {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('已刷新 $name')));
          } else if (v == 'edit') {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('编辑直播源')));
          } else if (v == 'delete') {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('删除 $name')));
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
              value: 'refresh',
              child: Text('立即刷新', style: TextStyle(color: Colors.white70))),
          PopupMenuItem(
              value: 'edit',
              child: Text('编辑直播源', style: TextStyle(color: Colors.white70))),
          PopupMenuItem(
              value: 'delete',
              child: Text('删除',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
  }

  Widget _addTile() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppTheme.accentColor.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.add, color: AppTheme.accentColor, size: 20),
      ),
      title: const Text('添加直播源',
          style: TextStyle(color: Colors.white, fontSize: 15)),
      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
      onTap: () async {
        final url = await showDialog<String>(
          context: context,
          builder: (ctx) {
            final ctrl = TextEditingController();
            return AlertDialog(
              backgroundColor: const Color(0xFF1C1C1E),
              title: const Text('添加直播源',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              content: TextField(
                controller: ctrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'm3u / txt 地址',
                  hintStyle: TextStyle(color: Colors.white38),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                    child: const Text('添加')),
              ],
            );
          },
        );
        if (url != null && url.isNotEmpty) {
          await LiveService.instance.loadFromUrl(url);
          setState(() {});
        }
      },
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text('暂无直播源，可添加 m3u 地址',
            style: TextStyle(color: Colors.white38, fontSize: 13)),
      ),
    );
  }
}
