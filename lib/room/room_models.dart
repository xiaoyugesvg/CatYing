/// 「一起看」房间的数据模型 —— 与 watch-room-server 的 Socket.IO 载荷一一对应。
///
/// 服务端类型定义见：
/// https://github.com/tgs9915/watch-room-server/blob/master/src/types.ts
///
/// 关键事件（客户端视角）：
///   room:create / room:join / room:leave / room:list
///   play:update（房主定时状态）/ play:seek / play:play / play:pause / play:change
///   chat:message / state:cleared / room:member-joined / room:member-left / room:deleted
library;

/// 房间里的播放状态（服务端 `PlayState`）
class PlayState {
  const PlayState({
    required this.url,
    this.currentTime = 0,
    this.isPlaying = false,
    this.videoId = '',
    this.videoName = '',
    this.videoYear = '',
    this.searchTitle = '',
    this.episode,
    this.source = '',
    this.headers = const {},
  });

  final String url;

  /// 秒
  final double currentTime;
  final bool isPlaying;

  /// 原始片源里的剧集标识（MoonTVPlus 用来在自己库里二次定位；
  /// 我们直接播 [url]，这两个字段只用于显示与重进房时恢复片名）
  final String videoId;
  final String videoName;
  final String videoYear;
  final String searchTitle;
  final int? episode;
  final String source;

  /// 播放该地址需要的请求头。
  ///
  /// watch-room-server 的类型里没有这个字段，但它把 `currentState`
  /// 原样存下、原样转发，所以附加字段能完整传到其他人手里。
  /// 不带的话，防盗链源在别人手机上就是"能进房间但黑屏"。
  final Map<String, String> headers;

  String get title {
    final name = videoName.isNotEmpty ? videoName : searchTitle;
    if (name.isEmpty) return '正在播放';
    return episode == null ? name : '$name · 第 $episode 集';
  }

  Map<String, dynamic> toJson() => {
        'type': 'play',
        'url': url,
        'currentTime': currentTime,
        'isPlaying': isPlaying,
        'videoId': videoId,
        'videoName': videoName,
        'videoYear': videoYear,
        'searchTitle': searchTitle,
        if (episode != null) 'episode': episode,
        'source': source,
        if (headers.isNotEmpty) 'headers': headers,
      };

  factory PlayState.fromJson(Map<String, dynamic> j) => PlayState(
        url: '${j['url'] ?? ''}',
        currentTime: (j['currentTime'] as num?)?.toDouble() ?? 0,
        isPlaying: j['isPlaying'] == true,
        videoId: '${j['videoId'] ?? ''}',
        videoName: '${j['videoName'] ?? ''}',
        videoYear: '${j['videoYear'] ?? ''}',
        searchTitle: '${j['searchTitle'] ?? ''}',
        episode: (j['episode'] as num?)?.toInt(),
        source: '${j['source'] ?? ''}',
        headers: _headers(j['headers']),
      );

  static Map<String, String> _headers(dynamic raw) {
    final out = <String, String>{};
    if (raw is Map) raw.forEach((k, v) => out['$k'] = '$v');
    return out;
  }
}

/// 房间信息（服务端 `Room`）
class RoomInfo {
  const RoomInfo({
    required this.id,
    required this.name,
    this.description = '',
    this.password = '',
    this.isPublic = true,
    this.roomType = 'sync',
    this.ownerName = '',
    this.ownerToken = '',
    this.memberCount = 1,
    this.createdAt = 0,
    this.currentState,
  });

  final String id;
  final String name;
  final String description;

  /// 服务端会把密码一起返回（仅用于判断是否有锁）；不展示给用户
  final String password;
  final bool isPublic;

  /// sync / screen / music
  final String roomType;
  final String ownerName;

  /// 房主重连凭证：建房时拿到，重进房间带上它就能恢复"房主"身份
  final String ownerToken;
  final int memberCount;
  final int createdAt;
  final PlayState? currentState;

  bool get hasPassword => password.isNotEmpty;

  DateTime get created => DateTime.fromMillisecondsSinceEpoch(createdAt);

  factory RoomInfo.fromJson(Map<String, dynamic> j) {
    final st = j['currentState'];
    return RoomInfo(
      id: '${j['id'] ?? ''}',
      name: '${j['name'] ?? '未命名房间'}',
      description: '${j['description'] ?? ''}',
      password: '${j['password'] ?? ''}',
      isPublic: j['isPublic'] != false,
      roomType: '${j['roomType'] ?? 'sync'}',
      ownerName: '${j['ownerName'] ?? ''}',
      ownerToken: '${j['ownerToken'] ?? ''}',
      memberCount: (j['memberCount'] as num?)?.toInt() ?? 0,
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      currentState:
          st is Map ? PlayState.fromJson(st.cast<String, dynamic>()) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'password': password,
        'isPublic': isPublic,
        'roomType': roomType,
        'ownerName': ownerName,
        'ownerToken': ownerToken,
        'memberCount': memberCount,
        'createdAt': createdAt,
        'currentState': currentState?.toJson(),
      };
}

/// 房间成员（服务端 `Member`）
class RoomMemberInfo {
  const RoomMemberInfo({
    required this.id,
    required this.name,
    this.isOwner = false,
  });

  final String id;
  final String name;
  final bool isOwner;

  factory RoomMemberInfo.fromJson(Map<String, dynamic> j) => RoomMemberInfo(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? '成员'}',
        isOwner: j['isOwner'] == true,
      );
}

/// 聊天消息（服务端 `ChatMessage`）
class RoomChatMessage {
  const RoomChatMessage({
    required this.id,
    required this.userId,
    required this.userName,
    required this.content,
    this.type = 'text',
    this.timestamp = 0,
    this.system = false,
  });

  final String id;
  final String userId;
  final String userName;
  final String content;
  final String type;
  final int timestamp;

  /// 本地系统提示（"xx 加入房间"）—— 服务端不下发这类消息，由客户端自己补
  final bool system;

  factory RoomChatMessage.fromJson(Map<String, dynamic> j) => RoomChatMessage(
        id: '${j['id'] ?? ''}',
        userId: '${j['userId'] ?? ''}',
        userName: '${j['userName'] ?? ''}',
        content: '${j['content'] ?? ''}',
        type: '${j['type'] ?? 'text'}',
        timestamp: (j['timestamp'] as num?)?.toInt() ?? 0,
      );
}
