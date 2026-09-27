import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// DLNA 投屏 page
///
/// **参考**：PiliPlus-main/lib/pages/dlna/view.dart
///
/// 用法：
/// ```dart
/// Get.toNamed('/dlna', parameters: {
///   'url': playUrl,
///   'title': videoTitle,
/// });
/// ```
///
/// 流程：
/// 1. initState → DLNAManager.start()，开始扫描局域网内 DLNA/UPnP 设备
/// 2. 监听 devices.stream 实时显示新发现的设备
/// 3. 30 秒后自动 stop（避免长时间占用网络）
/// 4. 用户点击某个设备 → 调 device.setUrl(url, title) + device.play()
/// 5. 二次点击同一设备 → return（避免重复投屏）
class DLNAPage extends StatefulWidget {
  const DLNAPage({super.key});

  @override
  State<DLNAPage> createState() => _DLNAPageState();
}

class _DLNAPageState extends State<DLNAPage> {
  final DLNAManager _searcher = DLNAManager();
  final Map<String, DLNADevice> _deviceList = {};
  late final String _url = Get.parameters['url'] ?? '';
  late final String? _title = Get.parameters['title'];

  StreamSubscription? _devicesSub;
  Timer? _stopTimer;
  bool _isSearching = false;

  // #9/#47 投屏控制状态：当前设备 / 播放暂停 / 进度
  DLNADevice? _activeDevice;
  String _activeKey = '';
  bool _casting = false;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  Timer? _posTimer;

  @override
  void initState() {
    super.initState();
    _onSearch(isInit: true);
  }

  /// 启动 / 重新搜索
  ///
  /// [isInit] = true 表示页面初始化（不清空设备列表，保留旧列表等待新设备加入）
  /// [isInit] = false 表示用户手动点刷新（清空设备列表重新扫描）
  Future<void> _onSearch({bool isInit = false}) async {
    if (_isSearching) return;
    _isSearching = true;

    if (!isInit && mounted) {
      setState(() => _deviceList.clear());
    }

    try {
      final deviceManager = await _searcher.start();
      if (!mounted) return;
      // 30 秒后自动停止搜索
      _stopTimer?.cancel();
      _stopTimer = Timer(const Duration(seconds: 30), () {
        _searcher.stop();
        if (mounted) setState(() => _isSearching = false);
      });

      // 监听设备流
      _devicesSub?.cancel();
      _devicesSub = deviceManager.devices.stream.listen((deviceList) {
        if (mounted) {
          setState(() => _deviceList.addAll(deviceList));
        }
      });
    } catch (e) {
      debugPrint('DLNA start failed: $e');
      if (mounted) setState(() => _isSearching = false);
    }
  }

  @override
  void dispose() {
    _stopTimer?.cancel();
    _stopTimer = null;
    _posTimer?.cancel();
    _posTimer = null;
    _devicesSub?.cancel();
    _devicesSub = null;
    _searcher.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('投屏（DLNA）'),
        actions: [
          IconButton(
            tooltip: '重新搜索',
            onPressed: _onSearch,
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _buildBody(colorScheme),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (_isSearching && _deviceList.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text('正在搜索局域网内的 DLNA 设备…',
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    if (_deviceList.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.tv_off, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            const Text('没有发现 DLNA 设备',
                style: TextStyle(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              '请确认：\n'
              '1. 电视/投影仪与手机连接同一 WiFi\n'
              '2. 设备已开启 DLNA / AirPlay / Miracast 功能',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: _onSearch,
              icon: const Icon(Icons.refresh),
              label: const Text('重新搜索'),
            ),
          ],
        ),
      );
    }
    final keys = _deviceList.keys.toList();
    final cardOffset = _casting ? 1 : 0;
    return ListView.separated(
      itemCount: keys.length + (_isSearching ? 1 : 0) + cardOffset,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
      itemBuilder: (context, index) {
        if (_casting && index == 0) {
          return _buildControlCard();
        }
        final listIndex = index - cardOffset;
        if (listIndex == keys.length) {
          // 列表底部"还在搜索"提示
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text('继续搜索中…',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          );
        }
        final key = keys[listIndex];
        final device = _deviceList[key]!;
        return ListTile(
          leading: const Icon(Icons.tv, color: Colors.white70),
          title: Text(
            device.info.friendlyName,
            style: const TextStyle(color: Colors.white),
          ),
          subtitle: Text(key,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4), fontSize: 11)),
          trailing: const Icon(Icons.cast, color: Colors.white54),
          onTap: () => _castTo(device, key),
        );
      },
    );
  }

  Future<void> _castTo(DLNADevice device, String key) async {
    if (_url.isEmpty) {
      Get.snackbar('投屏失败', '视频地址为空', snackPosition: SnackPosition.BOTTOM);
      return;
    }
    try {
      // #30 先探活：设备离线时 getTransportInfo 会抛错，避免白点一次
      await device.getTransportInfo();
      // setUrl 把视频 URL 推到 DMR；play 触发 DMR 开始播放
      await device.setUrl(_url, title: _title ?? '');
      await device.play();
      if (!mounted) return;
      setState(() {
        _activeDevice = device;
        _activeKey = key;
        _casting = true;
        _isPlaying = true;
        _position = Duration.zero;
        _duration = null;
      });
      _startPosTimer();
      Get.snackbar(
        '投屏成功',
        '正在 ${device.info.friendlyName} 上播放：${_title ?? ''}',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.black87,
        colorText: Colors.white,
      );
    } catch (e) {
      debugPrint('DLNA cast failed: $e');
      if (!mounted) return;
      Get.snackbar('投屏失败', '设备可能已离线：$e',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade700,
          colorText: Colors.white);
    }
  }

  // ===== #9 投屏控制（暂停/恢复/停止/进度） =====
  Future<void> _pauseCast() async {
    try {
      await _activeDevice!.pause();
      if (mounted) setState(() => _isPlaying = false);
    } catch (_) {
      _offlineHint();
    }
  }

  Future<void> _resumeCast() async {
    try {
      await _activeDevice!.play();
      if (mounted) setState(() => _isPlaying = true);
    } catch (_) {
      _offlineHint();
    }
  }

  Future<void> _stopCast() async {
    try {
      await _activeDevice!.stop();
    } catch (_) {
      // 停止失败也照常退出控制态
    }
    _posTimer?.cancel();
    _posTimer = null;
    if (mounted) {
      setState(() {
        _activeDevice = null;
        _casting = false;
        _isPlaying = false;
      });
    }
  }

  Future<void> _seekCast(double seconds) async {
    if (_activeDevice == null) return;
    try {
      // dlna_dart 的 seek 需基于当前 position 的相对偏移
      final xml = await _activeDevice!.position();
      final cur = _parseTime(xml, 'RelTime');
      final delta = (seconds - cur.inSeconds).round();
      await _activeDevice!.seekByCurrent(xml, delta);
      if (mounted) {
        setState(() => _position = Duration(seconds: seconds.round()));
      }
    } catch (_) {
      _offlineHint();
    }
  }

  void _startPosTimer() {
    _posTimer?.cancel();
    _posTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pollPosition());
  }

  Future<void> _pollPosition() async {
    if (_activeDevice == null || !mounted) return;
    try {
      // GetPositionInfo 的 XML 响应：<RelTime>HH:MM:SS</RelTime> + <TrackDuration>
      final xml = await _activeDevice!.position();
      if (!mounted || xml.isEmpty) return;
      setState(() {
        _position = _parseTime(xml, 'RelTime');
        final d = _parseTime(xml, 'TrackDuration');
        _duration = d > Duration.zero ? d : null;
      });
    } catch (_) {
      // 设备瞬时不可达：静默，下次再轮询
    }
  }

  /// 从 GetPositionInfo XML 中解析 HH:MM:SS(.fff) 时间
  Duration _parseTime(String xml, String tag) {
    final m = RegExp('<$tag>([^<]+)</$tag>').firstMatch(xml);
    if (m == null) return Duration.zero;
    final t = m.group(1)!.trim();
    if (t.isEmpty) return Duration.zero;
    final parts = t.split(':');
    if (parts.length != 3) return Duration.zero;
    final h = int.tryParse(parts[0]) ?? 0;
    final min = int.tryParse(parts[1]) ?? 0;
    final sec = double.tryParse(parts[2]) ?? 0;
    return Duration(seconds: h * 3600 + min * 60 + sec.round());
  }

  void _offlineHint() {
    Get.snackbar('设备离线',
        '无法控制 ${_activeDevice?.info.friendlyName ?? '当前设备'}',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade700,
        colorText: Colors.white);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // #47 投屏控制卡（列表顶部）
  Widget _buildControlCard() {
    final maxSec = (_duration ?? const Duration(minutes: 30)).inSeconds;
    final posSec = _position.inSeconds.clamp(0, maxSec).toDouble();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cast, color: Theme.of(context).colorScheme.primary, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '正在投屏到 ${_activeDevice!.info.friendlyName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if ((_title ?? '').isNotEmpty)
            Text(_title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(_fmt(_position),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.54), fontSize: 11)),
              Expanded(
                child: Slider(
                  value: posSec.clamp(0, maxSec.toDouble()),
                  max: maxSec.toDouble(),
                  onChanged: _seekCast,
                  activeColor: Theme.of(context).colorScheme.primary,
                  inactiveColor: Colors.white24,
                ),
              ),
              Text(_fmt(_duration ?? _position),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.54), fontSize: 11)),
            ],
          ),
          Row(
            children: [
              IconButton(
                tooltip: _isPlaying ? '暂停' : '播放',
                onPressed: _isPlaying ? _pauseCast : _resumeCast,
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white),
              ),
              IconButton(
                tooltip: '停止投屏',
                onPressed: _stopCast,
                icon: const Icon(Icons.stop, color: Colors.white),
              ),
              const Spacer(),
              Text('进度每 3 秒刷新',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.38), fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }
}
