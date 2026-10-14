import 'package:shared_preferences/shared_preferences.dart';

import '../services/prefs_mirror.dart';

/// 「网页首页」模块的配置（**独立于小程序体系**）。
///
/// 只存一个东西：用户配置的首页地址。
/// 为空 ⇒ 用**内置默认页** `assets/webhome/index.html`。
///
/// 持久化走 prefs（键 `webhome_url`），并且每次改完都调
/// [PrefsMirror.snapshotSoon] —— 立刻落盘 plist + 立刻写文件镜像，
/// 与其它设置项同一套兜底（防止"改完立刻被杀 → 重启变回旧值"）。
class WebHomePrefs {
  WebHomePrefs._();
  static final WebHomePrefs instance = WebHomePrefs._();

  static const String _kUrl = 'webhome_url';

  String _url = '';
  String get url => _url;

  /// 是否已从 prefs 读过（首帧读盘可能跨帧）。
  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _url = (p.getString(_kUrl) ?? '').trim();
    } catch (_) {
      // 读失败按"未配置"起步（走内置默认页），不影响启动
    }
    _loaded = true;
  }

  /// 设置首页地址；传空串 = 恢复内置默认页。
  Future<void> setUrl(String url) async {
    _url = url.trim();
    try {
      final p = await SharedPreferences.getInstance();
      if (_url.isEmpty) {
        await p.remove(_kUrl);
      } else {
        await p.setString(_kUrl, _url);
      }
    } catch (_) {
      // 写失败不抛：内存值已更新，本次会话仍生效
    }
    PrefsMirror.snapshotSoon();
  }
}
