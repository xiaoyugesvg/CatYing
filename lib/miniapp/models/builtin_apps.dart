import 'package:flutter/material.dart';

/// 内置小程序注册表。
///
/// 新增官方市场小程序：把 zip 解压到 `assets/miniapps/<目录>`（含
/// manifest.json），在 [builtinMiniApps] 加一项即可出现在「程序」页。
class BuiltinMiniApp {
  final String appId;
  final String name;
  final String assetRoot;
  final String tag;
  final IconData icon;
  final Color? tint;

  const BuiltinMiniApp({
    required this.appId,
    required this.name,
    required this.assetRoot,
    required this.tag,
    required this.icon,
    this.tint,
  });
}

/// 内置列表（按展示顺序）。
const List<BuiltinMiniApp> builtinMiniApps = <BuiltinMiniApp>[
  BuiltinMiniApp(
    appId: 'com.leospring.nemby',
    name: '新影视库',
    assetRoot: 'assets/miniapps/nemby',
    tag: '内置 · 影视浏览',
    icon: Icons.movie_filter_outlined,
    tint: Color(0xFF4FC3F7),
  ),
  BuiltinMiniApp(
    appId: 'com.ant.emby',
    name: '影视库',
    assetRoot: 'assets/miniapps/emby',
    tag: '官方 · Emby 风格',
    icon: Icons.video_library_outlined,
    tint: Color(0xFF7E57C2),
  ),
  BuiltinMiniApp(
    appId: 'com.leospring.web_links',
    name: '网页跳转示例',
    assetRoot: 'assets/miniapps/web-links',
    tag: '官方 · 示例',
    icon: Icons.open_in_browser_outlined,
    tint: Color(0xFF66BB6A),
  ),
];
