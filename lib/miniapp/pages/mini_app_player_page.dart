import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/media_resolver.dart';
import 'package:tvbox/services/parse_lines.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/parse_line_sheet.dart';
import 'package:tvbox/widgets/video_player.dart';

/// URL 直播放页（ant.player.open 用）。
///
/// 复用项目播放器内核（media_kit/libmpv + 弹幕 + PiP），
/// 黑底全屏，进页即播。带取流请求头（source.play 返回的 header 原样透传）。
///
/// ── 也是海阔 / RSS / 小程序的**共用播放页**（2026-10-31）──────────
/// 这三端都是「原始网页地址 → 嗅探出直链 → 进这里播」。进了本页之后
/// 原始地址就丢了，用户想「换一条解析线路」没入口 —— 用户原话：
/// 「播放器下面没有切换线路的按钮吗？不管是默认详情里面的还是纯竖屏的
/// 播放器呢」。所以本页收一个 [sourcePageUrl]：传了就在底栏出「线路」
/// 按钮，换完自己重新嗅探并热替换地址。
class MiniAppPlayerPage extends StatefulWidget {
  final String url;
  final String title;
  final Map<String, String>? headers;

  /// 这条 [url] 是从哪个**网页地址**嗅探出来的（没有解析环节就传 null）。
  ///
  /// 传了才显示「切换线路」按钮 —— 直链 / TG 取流 / 本地文件没有"线路"
  /// 这个概念，硬给一个按钮点了也没用。
  final String? sourcePageUrl;

  /// 重新嗅探 [sourcePageUrl] 时带的请求头（一般是源站要求的 Referer/UA）。
  final Map<String, String>? sourceHeaders;

  const MiniAppPlayerPage({
    super.key,
    required this.url,
    this.title = '',
    this.headers,
    this.sourcePageUrl,
    this.sourceHeaders,
  });

  @override
  State<MiniAppPlayerPage> createState() => _MiniAppPlayerPageState();
}

class _MiniAppPlayerPageState extends State<MiniAppPlayerPage> {
  /// 探测中（进播放器前的轻量加载）
  bool _probing = false;

  /// TG 播放失败的具体原因（null = 探测通过 / 非 TG 不探测）
  String? _probeError;

  /// 当前实际在播的地址（换线路后会变）
  late String _url = widget.url;

  /// 换线路重新嗅探中
  bool _switching = false;

  /// 是不是 TG 源的取流地址（本机回环 `/tg/…` 或远程 `…/tg/…`）
  bool get _isTg => _url.contains('/tg/');

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
        _url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: const {'Range': 'bytes=0-1'},
          validateStatus: (_) => true,
          // TG 取流要先回一趟 Telegram 机房拿首块，6s 对慢网/大文件太紧，
          // 会把"只是慢"报成失败（用户 2026-10-29「加载出来画面但播放超时」）。
          // Node 侧已按实际区间收窄请求（探流只取 4KB 而不是 256KB），
          // 这里放宽到 15s 只是兜底。
          receiveTimeout: const Duration(seconds: 15),
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
    } on DioException catch (e) {
      // 超时不要说成"无法连接"——两者给用户的下一步动作不一样
      err = (e.type == DioExceptionType.receiveTimeout ||
              e.type == DioExceptionType.connectionTimeout)
          ? '取流超时（15 秒没收到数据）。\n'
              '大文件/慢网下第一次起播可能就要这么久，点「重试」再试一次；\n'
              '仍然不行就去 TG 设置里开「内置代理池」。'
          : '无法连接 TG 取流服务：${e.message ?? e}';
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

  // ============================================================
  // 切换解析线路（海阔 / RSS / 小程序共用）
  // ============================================================

  /// 弹线路列表 → 换线路 → 拿原始网页地址重新嗅探 → 热替换地址。
  ///
  /// 为什么必须回到**原始网页地址**重解：解析线路就是个前缀
  /// （`jx.xx/?url=<原始地址>`），手上这条 m3u8 是上一条前缀的产物，
  /// 拿它套新前缀没有意义。
  Future<void> _switchParseLine() async {
    final page = (widget.sourcePageUrl ?? '').trim();
    if (page.isEmpty || _switching) return;
    final picked = await showParseLineSheet(context);
    if (picked == null || !mounted) return;
    if (picked == ParseLineStore.instance.selectedId) {
      AppToast.message('已经是这条线路了');
      return;
    }

    setState(() => _switching = true);
    try {
      await ParseLineStore.instance.setSelected(picked);
      // 缓存 key 是页面地址，换线路后地址没变 —— 不清就把旧线路结果还回来
      MediaResolver.instance.clearCache();
      final name =
          picked.isEmpty ? '自动' : (ParseLineStore.instance.selected?.name ?? picked);
      AppLog.instance.log('[Player] 切换解析线路 → $name，重新嗅探 $page');
      AppToast.message('已切到「$name」，重新嗅探中…');

      final found = await MediaResolver.instance.resolve(
        page,
        headers: widget.sourceHeaders ?? const {},
        sniffFirst: true,
      );
      if (!mounted) return;
      final direct = (found ?? '').trim();
      if (direct.isEmpty) {
        AppToast.message('这条线路没抓到地址，换一条试试');
        return;
      }
      setState(() {
        _url = direct;
        _probeError = null;
      });
    } catch (e) {
      AppLog.instance.w('[Player] 换线路失败: $e');
      if (mounted) AppToast.message('换线路失败：$e');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Widget _buildBody() {
    if (_probing || _switching) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white70),
            if (_switching) ...[
              const SizedBox(height: 14),
              const Text('正在用新线路重新嗅探…',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ],
        ),
      );
    }
    if (_probeError != null) {
      return _error(_probeError!);
    }
    return VideoPlayerWidget(
      // key 带上地址：换线路后地址变了 ⇒ 整体 remount，内核干净重开
      key: ValueKey('ant_player_$_url'),
      url: _url,
      videoTitle: widget.title.isEmpty ? '播放' : widget.title,
      headers: widget.headers,
      // TG 源每个分片都要回一趟 Telegram 机房，首块+缓冲延迟天然比 CDN 高。
      // 15s 的通用阈值会把"慢"误判成"坏"（弹出「加载超时」），这里放到 45s。
      stallSeconds: _isTg ? 45 : 15,
      // 顶栏返回键由播放器自带、且**无条件显示**；不传 onBack 时点了
      // 什么都不会发生（只能靠系统手势退出）—— 2026-10-15 修复。
      onBack: () => Navigator.of(context).maybePop(),
      // 有原始网页地址才有"线路"可换
      onSwitchParseLine:
          (widget.sourcePageUrl ?? '').trim().isEmpty ? null : _switchParseLine,
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
