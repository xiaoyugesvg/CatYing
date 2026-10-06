// lib/reading/pages/shell_embedded_page.dart
//
// ✅ **外壳内嵌子页的全局开关**（本轮重构 ✓）
//
// 背景 ✗（用户反复要的"**悬浮菜单栏**"= 底部那条 5 项胶囊导航栏 ✓）：
//   · 底栏是**外壳**（`home_page.dart:386 bottomNavigationBar: JellyNavBar(...)` ✓）画的 ✓
//   · 而书源页 / 搜索页原来用 `Navigator.push` **全屏推出** ✗ ⇒ 底栏被盖掉 ✗✓
//     ⇒ 表现为"**书源页没有底栏**"✗（用户截图 ✓）
//
// 做法 ✓：这些页面**别自己 push** ✗ —— 改成把页面塞进这里 ✓
//   ⇒ 外壳监听到后，**在自己的 body 里渲染它** ✓ ⇒ 底栏**照常显示** ✓✓
//   ⇒ 于是"书源页 / 书源搜索结果 / 图书搜索结果"**全都带着底栏** ✓（与漫画/图书页一致 ✓）
//
// 用法 ✓：
//   打开：`openEmbeddedPage(const BookSourceSearchPage());`
//   关闭：`closeEmbeddedPage();`（子页自己的返回键调用 ✓ 回到原 tab ✓）
//
// ℹ️ 为什么用 `ValueNotifier` ✗ 而不是给每个页面传回调：
//   调用点分散（书源页、搜索结果、将来的页面 ✓），传回调要改一串构造签名 ✗；
//   用全局 notifier ✓ = **只改"打开"那一行** ✓ 最小侵入 ✓（与本仓既有 `ValueNotifier` 用法一致 ✓）
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 当前"内嵌子页"✓（null = 不显示 ✓ 外壳照常显示 tab 内容 ✓）
final ValueNotifier<Widget?> shellEmbeddedPage = ValueNotifier<Widget?>(null);

/// 打开内嵌子页 ✓（**底栏仍在** ✓）
void openEmbeddedPage(Widget page) => shellEmbeddedPage.value = page;

/// 关闭内嵌子页 ✓（回到当前 tab ✓）
void closeEmbeddedPage() => shellEmbeddedPage.value = null;
