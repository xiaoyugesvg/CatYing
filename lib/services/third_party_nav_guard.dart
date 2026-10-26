import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/ad_block_service.dart';

/// 网页内跳转守卫：**默认禁止跳第三方网站**，先弹窗确认。
///
/// 用户 2026-10-20：「网页里面如果跳转第三方网站就加个弹窗是否跳转，
/// 一般情况禁止网页模式跳转第三方网站」。
///
/// 判定口径：
///   · 同站（同域名 / 子域 / 主域相同）→ 直接放行；
///   · `tel:` / `mailto:` / `intent:` / `market:` 等非 http 协议 → 视为第三方；
///   · 其余跨站 → 受「设置 → 广告管理 → 禁止跳转第三方网站」开关控制，
///     开启时弹窗，用户点「继续访问」才放行（同一站点本次会话内记住，避免
///     页面反复重定向时连环弹窗）。
class ThirdPartyNavGuard {
  ThirdPartyNavGuard._();

  /// 本次会话里用户已确认放行的域名（不落盘，重启重置）
  static final Set<String> _allowedHosts = {};

  static String hostOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return '';
    return u.host.toLowerCase();
  }

  /// 两个地址是否同一个站点（含子域）。
  static bool sameSite(String a, String b) {
    final ha = hostOf(a);
    final hb = hostOf(b);
    if (ha.isEmpty || hb.isEmpty) return ha == hb;
    if (ha == hb) return true;
    return ha.endsWith('.$hb') || hb.endsWith('.$ha');
  }

  static bool _isHttp(String url) =>
      url.startsWith('http://') || url.startsWith('https://');

  /// 是否属于「第三方跳转」。
  static bool isThirdParty(String target, String siteUrl) {
    if (!_isHttp(target)) return true;
    if (siteUrl.isEmpty) return false;
    return !sameSite(target, siteUrl);
  }

  /// 在 `onNavigationRequest` 里调用。
  static Future<NavigationDecision> decide(
    BuildContext context, {
    required String target,
    required String siteUrl,
  }) async {
    if (!isThirdParty(target, siteUrl)) return NavigationDecision.navigate;
    // 开关关闭 = 不拦
    if (!AdBlockService.instance.blockThirdParty) {
      return NavigationDecision.navigate;
    }
    final host = hostOf(target);
    if (host.isNotEmpty && _allowedHosts.contains(host)) {
      return NavigationDecision.navigate;
    }
    // 页面自己的相对地址 / 空地址不拦
    if (target.isEmpty || target.startsWith('about:') || target.startsWith('data:')) {
      return NavigationDecision.navigate;
    }
    if (!context.mounted) return NavigationDecision.prevent;

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '即将离开当前网站',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: Text(
          '当前网页要跳转到第三方站点：\n${host.isEmpty ? target : host}\n\n是否继续？',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('禁止'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('继续访问'),
          ),
        ],
      ),
    );
    if (go == true) {
      if (host.isNotEmpty) _allowedHosts.add(host);
      return NavigationDecision.navigate;
    }
    return NavigationDecision.prevent;
  }
}
