import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/pages/play/sniff_player_page.dart';
import 'package:tvbox/models/app_config.dart';
import 'package:tvbox/services/parse_service.dart';
import 'package:tvbox/services/parse_store.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/parse_sniff_sheet.dart';
import 'package:tvbox/widgets/playback_surface.dart';
import 'package:tvbox/widgets/video_player.dart';

/// URL 直播放页（ant.player.open 用）。
///
/// 复用项目播放器内核（media_kit/libmpv + 弹幕 + PiP），
/// 黑底全屏，进页即播。带取流请求头（source.play 返回的 header 原样透传）。
class MiniAppPlayerPage extends StatefulWidget {
  final String url;
  final String title;
  final Map<String, String>? headers;

  const MiniAppPlayerPage({
    super.key,
    required this.url,
    this.title = '',
    this.headers,
  });

  @override
  State<MiniAppPlayerPage> createState() => _MiniAppPlayerPageState();
}

class _MiniAppPlayerPageState extends State<MiniAppPlayerPage> {
  /// 探测中（进播放器前的轻量加载）
  bool _probing = false;

  /// TG 播放失败的具体原因（null = 探测通过 / 非 TG 不探测）
  String? _probeError;

  /// 解析后替换的直链（null = 用 widget.url）。小程序 / RSS 这类纯 URL
  /// 播放页没有详情页控制器，解析成功就靠它重载播放器（2026-10-28）。
  String? _overrideUrl;

  /// 解析接口自带的请求头（防盗链 Referer/UA 等）。
  ///
  /// 之前 `_openParse` 用 `parse()` 只拿回了地址字符串、把 header 丢了，
  /// 导致"解析明明成功却播不了"（解析站给的直链很多要带 Referer）。
  /// 这里和直链一起缓存，重载播放器时一并带过去（2026-10-28 修复）。
  Map<String, String>? _overrideHeaders;

  String get _effectiveUrl => _overrideUrl ?? widget.url;

  /// 实际喂给播放器的请求头：解析覆盖了就用解析带的，否则用源传入的。
  Map<String, String>? get _effectiveHeaders =>
      _overrideHeaders ?? widget.headers;

  /// 是不是 TG 源的取流地址（本机回环 `/tg/…` 或远程 `…/tg/…`）
  bool get _isTg => widget.url.contains('/tg/');

  @override
  void initState() {
    super.initState();
    // ── TG 源在进播放器前先探一次流 ────────────────────────
    // Node 失败时返回的是 **JSON 错误**（401 未登录 / 404 解析不出 /
    // 502 取流失败 / 500 异常），AVPlayer 拿到 JSON 只报一个「HTTP 502」，
    // 用户看到的就永远是**无限转圈**（2026-10-26 日志实锤：
    //   stream error: …CoreMediaErrorDomain error -16848 - HTTP 502）。
    // 这里用 Range 探一下：能出字节就交给播放器，出 JSON 错误就把
    // Node 的友好文案直接显示出来，不再靠猜。
    if (_isTg) {
      _probing = true;
      _probe();
    }
  }

  Future<void> _probe() async {
    String? err;
    try {
      final r = await Dio().get(
        widget.url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: const {'Range': 'bytes=0-1'},
          validateStatus: (_) => true,
          receiveTimeout: const Duration(seconds: 6),
        ),
      );
      final code = r.statusCode ?? 0;
      if (code >= 200 && code < 300) {
        err = null; // 能出字节 → 交给播放器
      } else {
        err = 'HTTP $code';
        final data = r.data;
        if (data is List && data.isNotEmpty) {
          try {
            final s = utf8.decode(data.cast<int>());
            if (s.trimLeft().startsWith('{')) {
              final j = jsonDecode(s);
              if (j is Map && j['error'] is String) {
                err = j['error'] as String;
              }
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      err = '无法连接 TG 取流服务：$e';
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeError = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // 不再自画返回按钮：播放器自带返回键（用户 2026-10-14），
      // 两个返回叠在一起既重复又挡画面。
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_probing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    if (_probeError != null) {
      return _error(_probeError!);
    }
    return VideoPlayerWidget(
      key: ValueKey('ant_player_$_effectiveUrl'),
      url: _effectiveUrl,
      videoTitle: widget.title.isEmpty ? '播放' : widget.title,
      headers: _effectiveHeaders,
      // 顶栏返回键由播放器自带、且**无条件显示**；不传 onBack 时点了
      // 什么都不会发生（只能靠系统手势退出）—— 2026-10-15 修复。
      // 从嗅探页进来时回到嗅探页，从小程序进来时回到小程序页。
      onBack: () => Navigator.of(context).maybePop(),
      // 嗅探 / 解析：常驻按钮（2026-10-28）。小程序 / RSS 复用页没有详情页
      // 控制器，这里用自包含逻辑 —— 嗅探打开嗅探页、解析用 ParseService 直解。
      onSniff: _openSniff,
      onSwitchParse: _openParse,
    );
  }

  /// 嗅探：当前若是网页地址才嗅，否则提示。成功后由嗅探页自行跳转新播放页。
  Future<void> _openSniff() async {
    final url = _effectiveUrl;
    if (!url.startsWith('http')) {
      AppToast.message('当前地址不是网页，无法嗅探');
      return;
    }
    Get.to(() => SniffPlayerPage(
          url: url,
          title: widget.title.isEmpty ? null : widget.title,
          headers: _effectiveHeaders,
        ));
  }

  /// 解析：选线路后用 ParseService 直解当前 URL。
  ///
  /// 三个修复点（2026-10-28，对应审计 P0-2）：
  ///   ① 用 [ParseService.parseOutcome] 而非 [ParseService.parse] —— 把解析
  ///      接口自带的防盗链头一起带出来，重载播放器时随直链一起喂给播放器；
  ///   ② 判 [ParseOutcome.direct]：解析出来仍是网页（type 0 通用解析站返回
  ///      播放页）就转内嵌网页播放器继续嗅探，而不是把网页塞进原生播放器
  ///      黑屏；
  ///   ③ 真正用上 onPickLine 回调里的 [lineUrl]（选中的线路 url），严格按
  ///      `only: bean` 解析，而不是只靠面板 `setActive` 的副作用。
  Future<void> _openParse() async {
    await ParseSniffSheet.show(
      context,
      section: ParseSniffSection.parse,
      onPickLine: (lineUrl) async {
        // lineUrl = '' 表示「自动（按顺序）」，否则为某条线路的 url。
        ParseBean? bean;
        if (lineUrl.isNotEmpty) {
          for (final b in ParseStore.instance.list) {
            if (b.url == lineUrl) {
              bean = b;
              break;
            }
          }
        }
        final outcome = await ParseService.instance.parseOutcome(
          _effectiveUrl,
          only: bean,
          headers: widget.headers,
        );
        if (!mounted) return;
        if (outcome == null) {
          AppToast.message('解析失败，请换条线路或检查网络');
          return;
        }
        if (outcome.direct) {
          // 直链：带上解析接口自带的防盗链头，重载原生播放器。
          Map<String, String>? headers = outcome.headers;
          // 「播放带 Referer」开关打开时，解析结果也补 Referer（P2-2 一致性）；
          // 以源传入的 header 打底，避免只带 Referer 把源给的 UA/Cookie 丢掉。
          if (PlayerPrefs.instance
              .shouldSendRefererFor(_effectiveUrl, outcome.url)) {
            headers = <String, String>{...?widget.headers, ...?outcome.headers}
              ..putIfAbsent('Referer', () => _effectiveUrl.trim());
          }
          setState(() {
            _overrideUrl = outcome.url;
            _overrideHeaders = headers;
          });
          AppToast.message('解析成功，已切换直链');
        } else {
          // 解析出来仍是网页：丢给内嵌网页播放器，它会继续嗅探出直链；
          // 直接塞原生播放器会黑屏（2026-10-15 深挖）。
          AppToast.message('解析返回网页，转内嵌网页嗅探');
          Get.to(() => PlaybackSurface.webFallback(
                url: outcome.url,
                title: widget.title.isEmpty ? null : widget.title,
                // 后台嗅探放弃（未命中）→ 提示别对网页干等（2026-10-28）
                onSniffGaveUp: () => AppToast.message(
                    '未嗅探到直链，可返回重试或换线路'),
              ));
        }
      },
    );
  }

  Widget _error(String msg) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  color: Colors.white70, size: 44),
              const SizedBox(height: 18),
              Text(
                'TG 视频取流失败',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                msg,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '提示：登录频道需先扫码登录；连不上 Telegram 时，'
                '去 TG 设置里开启「内置代理池」再试',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 26),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _probing = true;
                        _probeError = null;
                      });
                      _probe();
                    },
                    child: const Text('重试',
                        style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(width: 18),
                  FilledButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('返回'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
