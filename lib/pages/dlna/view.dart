import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../services/app_log.dart';

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
/// 5. 已投屏设备可控制：暂停/继续/停止
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

  /// 当前正在投屏的设备 key（null 表示未投屏）
  String? _activeDeviceKey;

  /// 当前投屏设备的播放状态
  bool _isPlaying = false;

  /// 是否正在执行控制操作（防止重复点击）
  bool _isControlBusy = false;

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
      AppLog.instance.log('DLNA start failed: $e');
      if (mounted) setState(() => _isSearching = false);
    }
  }

  @override
  void dispose() {
    _stopTimer?.cancel();
    _stopTimer = null;
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
      body: Column(
        children: [
          Expanded(child: _buildBody(colorScheme)),
          // 底部投屏控制栏（仅在已投屏时显示）
          if (_activeDeviceKey != null) _buildActiveCastBar(),
        ],
      ),
    );
  }

  /// 底部"正在投屏"控制栏
  Widget _buildActiveCastBar() {
    final device = _deviceList[_activeDeviceKey];
    final deviceName = device?.info.friendlyName ?? '未知设备';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cast_connected,
                    color: Colors.greenAccent.shade400, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '正在投屏到 $deviceName',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _title ?? '',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // 暂停/继续
                IconButton(
                  onPressed: _isControlBusy ? null : _togglePause,
                  icon: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
                  tooltip: _isPlaying ? '暂停' : '继续播放',
                ),
                // 停止投屏
                IconButton(
                  onPressed: _isControlBusy ? null : _stopCast,
                  icon: const Icon(Icons.stop_circle_outlined,
                      color: Colors.white70),
                  tooltip: '停止投屏',
                ),
              ],
            ),
          ],
        ),
      ),
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
    return ListView.separated(
      itemCount: keys.length + (_isSearching ? 1 : 0),
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
      itemBuilder: (context, index) {
        if (index == keys.length) {
          // 列表底部"还在搜索"提示
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text('继续搜索中…',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          );
        }
        final key = keys[index];
        final device = _deviceList[key]!;
        final isActive = key == _activeDeviceKey;
        return ListTile(
          leading: Icon(
            isActive ? Icons.cast_connected : Icons.tv,
            color: isActive ? Colors.greenAccent.shade400 : Colors.white70,
          ),
          title: Text(
            device.info.friendlyName,
            style: TextStyle(
              color: isActive ? Colors.greenAccent.shade400 : Colors.white,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            isActive ? '正在播放' : key,
            style: TextStyle(
                color: isActive
                    ? Colors.greenAccent.shade400.withValues(alpha: 0.7)
                    : Colors.white.withValues(alpha: 0.4),
                fontSize: 11),
          ),
          trailing: Icon(
            isActive ? Icons.check_circle : Icons.cast,
            color: isActive ? Colors.greenAccent.shade400 : Colors.white54,
          ),
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
    // 同一设备：如果正在投屏则忽略；如果是其他设备则切换
    if (key == _activeDeviceKey && _isPlaying) {
      Get.snackbar(
        '提示',
        '当前已在此设备上播放',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.black87,
        colorText: Colors.white,
      );
      return;
    }
    setState(() => _isControlBusy = true);
    try {
      // setUrl 把视频 URL 推到 DMR；play 触发 DMR 开始播放
      await device.setUrl(_url, title: _title ?? '');
      await device.play();
      if (!mounted) return;
      setState(() {
        _activeDeviceKey = key;
        _isPlaying = true;
      });
      Get.snackbar(
        '投屏成功',
        '正在 ${device.info.friendlyName} 上播放：${_title ?? ''}',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.black87,
        colorText: Colors.white,
      );
    } catch (e) {
      AppLog.instance.log('DLNA cast failed: $e');
      if (!mounted) return;
      Get.snackbar('投屏失败', '$e',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade700,
          colorText: Colors.white);
    } finally {
      if (mounted) setState(() => _isControlBusy = false);
    }
  }

  /// 暂停/继续切换
  Future<void> _togglePause() async {
    final device = _deviceList[_activeDeviceKey];
    if (device == null) return;
    setState(() => _isControlBusy = true);
    try {
      if (_isPlaying) {
        await device.pause();
        if (mounted) setState(() => _isPlaying = false);
      } else {
        await device.play();
        if (mounted) setState(() => _isPlaying = true);
      }
    } catch (e) {
      AppLog.instance.log('DLNA control failed: $e');
      if (mounted) {
        Get.snackbar(
          '操作失败',
          '$e',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade700,
          colorText: Colors.white,
        );
      }
    } finally {
      if (mounted) setState(() => _isControlBusy = false);
    }
  }

  /// 停止投屏
  Future<void> _stopCast() async {
    final device = _deviceList[_activeDeviceKey];
    if (device == null) return;
    setState(() => _isControlBusy = true);
    try {
      await device.stop();
      if (mounted) {
        setState(() {
          _activeDeviceKey = null;
          _isPlaying = false;
        });
        Get.snackbar(
          '已停止投屏',
          '已断开与设备的连接',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.black87,
          colorText: Colors.white,
        );
      }
    } catch (e) {
      AppLog.instance.log('DLNA stop failed: $e');
      // 停止失败也强制清除本地状态，避免UI卡死
      if (mounted) {
        setState(() {
          _activeDeviceKey = null;
          _isPlaying = false;
        });
      }
    } finally {
      if (mounted) setState(() => _isControlBusy = false);
    }
  }
}
