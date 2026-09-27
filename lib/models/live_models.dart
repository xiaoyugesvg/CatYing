/// 直播频道 / 分组模型（2026-09-27 重做）
class LiveChannel {
  final String name;
  final List<String> urls;
  final String group;
  final String? logo;

  const LiveChannel({
    required this.name,
    required this.urls,
    this.group = '未分组',
    this.logo,
  });

  String get playUrl => urls.isNotEmpty ? urls.first : '';
}

class LiveGroup {
  final String name;
  final List<LiveChannel> channels;

  const LiveGroup({required this.name, required this.channels});
}
