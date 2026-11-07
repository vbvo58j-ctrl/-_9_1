import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bluetooth_classic_service.dart';
import 'local_network_service.dart';
import 'qr_friend_store.dart';
import 'wifi_aware_service.dart';

const String kDefaultTagline1 = 'أهلاً وسهلاً بكم في بلوساب 🩵';
const String kDefaultTagline2 = 'معاً نبني مجتمعاً أقوى';

/// بيانات ملف شخصي عام لمستخدم آخر (مخزّنة محلياً بعد استلامها).
class BlousabProfile {
  BlousabProfile({
    required this.id,
    this.name = '',
    this.photoPath = '',
    this.tag1 = '',
    this.tag2 = '',
    this.friends = 0,
    this.photoHash = '',
    this.lastSeen = 0,
  });
  final String id;
  String name;
  String photoPath;
  String tag1;
  String tag2;
  int friends;
  String photoHash;
  int lastSeen;

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'photoPath': photoPath, 'tag1': tag1, 'tag2': tag2,
        'friends': friends, 'photoHash': photoHash, 'lastSeen': lastSeen,
      };

  static BlousabProfile fromJson(Map<String, dynamic> j) => BlousabProfile(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        photoPath: j['photoPath']?.toString() ?? '',
        tag1: j['tag1']?.toString() ?? '',
        tag2: j['tag2']?.toString() ?? '',
        friends: (j['friends'] as num?)?.toInt() ?? 0,
        photoHash: j['photoHash']?.toString() ?? '',
        lastSeen: (j['lastSeen'] as num?)?.toInt() ?? 0,
      );
}

/// حالة التوفر (متصل / غير متوفر) + وضع الشبح + دليل الملفات الشخصية للآخرين.
///
/// كل جهاز نشط وغير متخفٍّ يبثّ نبضة «presence» صغيرة كل 8 ثوانٍ عبر كل الوسائل المتاحة
/// (شبكة محلية، Wi-Fi Aware، بلوتوث). يُعدّ المستخدم متصلاً إذا وصلت منه نبضة خلال 30 ثانية.
class BlousabPresence {
  BlousabPresence._();
  static final BlousabPresence instance = BlousabPresence._();

  static const String _ghostKey = 'blousab_ghost_mode_v1';
  static const String _dirKey = 'blousab_profile_dir_v1';
  static const int _onlineWindowMs = 30000;

  /// وضع الشبح: يُحفظ حتى يضغط المستخدم عليه مرة أخرى (لا يتأثر بإغلاق التطبيق).
  final ValueNotifier<bool> ghost = ValueNotifier<bool>(false);

  /// يزداد عند تغيّر حالة أي مستخدم أو بيانات ملفه.
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  final Map<String, int> _lastSeen = <String, int>{};
  final Map<String, BlousabProfile> _profiles = <String, BlousabProfile>{};
  final Map<String, int> _lastProfileRequest = <String, int>{};
  String _myId = '';
  bool _started = false;
  Timer? _heartbeat;
  Timer? _sweeper;
  StreamSubscription<dynamic>? _lanSub;
  StreamSubscription<dynamic>? _awareSub;
  StreamSubscription<dynamic>? _btSub;
  String _onlineSnapshot = '';
  String? _cachedPhotoPath;
  String _cachedPhotoHash = '';
  String _cachedPhotoB64 = '';

  String get myId => _myId;

  bool isOnline(String id) {
    if (id.isEmpty || id == _myId) return false;
    final seen = _lastSeen[id];
    if (seen == null) return false;
    return DateTime.now().millisecondsSinceEpoch - seen <= _onlineWindowMs;
  }

  BlousabProfile? profileOf(String id) => _profiles[id];

  String photoPathOf(String id) {
    final path = _profiles[id]?.photoPath ?? '';
    return path.isNotEmpty && File(path).existsSync() ? path : '';
  }

  String nameOf(String id, [String fallback = 'مستخدم بلوساب']) {
    final n = _profiles[id]?.name ?? '';
    return n.trim().isEmpty ? fallback : n;
  }

  /// تسجيل ما نعرفه عن مستخدم (من منشور أو تعليق وصل منه) دون انتظار نبضة.
  void register(String id, {String? name, String? photoPath}) {
    if (id.isEmpty || id == _myId) return;
    final p = _profiles.putIfAbsent(id, () => BlousabProfile(id: id));
    var changed = false;
    if (name != null && name.trim().isNotEmpty && p.name != name.trim()) { p.name = name.trim(); changed = true; }
    if (photoPath != null && photoPath.isNotEmpty && p.photoPath != photoPath) { p.photoPath = photoPath; changed = true; }
    if (changed) { _persistDir(); version.value++; }
  }

  /// هل لدينا منشورات سبق أن تزامنت من هذا المستخدم؟
  Future<bool> hasSyncedPosts(String id) async {
    if (id.isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final raw in prefs.getStringList('blousab_public_feed_v1') ?? const <String>[]) {
        try {
          final post = jsonDecode(raw);
          if (post is Map && post['authorId']?.toString() == id) return true;
        } catch (_) {}
      }
    } catch (_) {}
    return false;
  }

  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    _myId = prefs.getString('wasl_user_id') ?? '';
    if (_started) { unawaited(_beat()); return; }
    _started = true;
    ghost.value = prefs.getBool(_ghostKey) ?? false;
    try {
      final raw = prefs.getString(_dirKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            if (e.value is Map) {
              final p = BlousabProfile.fromJson(Map<String, dynamic>.from(e.value as Map));
              if (p.id.isNotEmpty) _profiles[p.id] = p;
            }
          }
        }
      }
    } catch (_) {}
    _lanSub = LocalNetworkService.instance.events.listen((e) => _onEvent(e.type, e.message));
    _btSub = BluetoothClassicService.instance.events.listen((e) => _onEvent(e.type, e.message));
    _awareSub = WifiAwareService.instance.events.listen((e) {
      if (e.type == 'dataPacket') {
        _onEvent('message', e.payload);
      } else if (e.type == 'dataConnected') {
        unawaited(_beat());
      }
    });
    _heartbeat = Timer.periodic(const Duration(seconds: 8), (_) => _beat());
    _sweeper = Timer.periodic(const Duration(seconds: 5), (_) => _sweep());
    unawaited(_beat());
  }

  Future<void> setGhost(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ghostKey, value);
    ghost.value = value;
    if (value) {
      // إبلاغ الآخرين فوراً بأنني لم أعد متوفراً.
      await _send(jsonEncode({'type': 'presence_off', 'senderId': _myId}));
    } else {
      await _beat();
    }
  }

  void _sweep() {
    unawaited(BlousabBadges.refresh());
    final now = DateTime.now().millisecondsSinceEpoch;
    final online = _lastSeen.entries.where((e) => now - e.value <= _onlineWindowMs).map((e) => e.key).toList()..sort();
    final snapshot = online.join(',');
    if (snapshot != _onlineSnapshot) {
      _onlineSnapshot = snapshot;
      version.value++;
    }
  }

  // ---- إرسال ----

  Future<void> _send(String payload) async {
    try {
      if (LocalNetworkService.instance.isRunning) await LocalNetworkService.instance.broadcastMessage(payload);
    } catch (_) {}
    try {
      if (WifiAwareService.instance.connectedPeerIds.isNotEmpty) await WifiAwareService.instance.broadcastPacket(payload);
    } catch (_) {}
    try {
      await BluetoothClassicService.instance.broadcastMessage(payload);
    } catch (_) {}
  }

  /// يرسل رسالة موجّهة (طلب صداقة، إلخ) عبر كل الوسائل المتاحة.
  Future<bool> sendPacket(String payload) async {
    var sent = false;
    try {
      if (LocalNetworkService.instance.isRunning) { await LocalNetworkService.instance.broadcastMessage(payload); sent = true; }
    } catch (_) {}
    try {
      if (WifiAwareService.instance.connectedPeerIds.isNotEmpty) { await WifiAwareService.instance.broadcastPacket(payload); sent = true; }
    } catch (_) {}
    try {
      await BluetoothClassicService.instance.broadcastMessage(payload);
      sent = true;
    } catch (_) {}
    return sent;
  }

  Future<Map<String, dynamic>> _myInfo({bool withPhoto = false}) async {
    final prefs = await SharedPreferences.getInstance();
    _myId = prefs.getString('wasl_user_id') ?? _myId;
    final photoPath = prefs.getString('wasl_profile_photo') ?? '';
    var hash = '';
    if (photoPath.isNotEmpty) {
      try {
        final f = File(photoPath);
        if (await f.exists()) hash = '${await f.length()}-${(await f.lastModified()).millisecondsSinceEpoch}';
      } catch (_) {}
    }
    final friends = (await QrFriendStore.loadFriends()).length;
    final info = <String, dynamic>{
      'senderId': _myId,
      'name': prefs.getString('wasl_user_name') ?? 'مستخدم بلوساب',
      'tag1': prefs.getString('blousab_profile_tag1') ?? kDefaultTagline1,
      'tag2': prefs.getString('blousab_profile_tag2') ?? kDefaultTagline2,
      'friends': friends,
      'photoHash': hash,
    };
    if (withPhoto && hash.isNotEmpty) {
      final b64 = await _photoBase64(photoPath, hash);
      if (b64.isNotEmpty) info['photo'] = b64;
    }
    return info;
  }

  /// صورة الملف الشخصي مصغّرة (حتى 256px) لتصل بسرعة عبر أي وسيلة.
  Future<String> _photoBase64(String path, String hash) async {
    if (_cachedPhotoPath == path && _cachedPhotoHash == hash) return _cachedPhotoB64;
    var out = '';
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.length <= 60 * 1024) {
        out = base64Encode(bytes);
      } else {
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 256);
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
        if (data != null && data.lengthInBytes <= 300 * 1024) out = base64Encode(data.buffer.asUint8List());
      }
    } catch (_) {}
    _cachedPhotoPath = path;
    _cachedPhotoHash = hash;
    _cachedPhotoB64 = out;
    return out;
  }

  Future<void> _beat() async {
    if (ghost.value) return;
    try {
      final info = await _myInfo();
      if (_myId.isEmpty) return;
      await _send(jsonEncode({'type': 'presence', 'ts': DateTime.now().millisecondsSinceEpoch, ...info}));
    } catch (_) {}
  }

  // ---- استقبال ----

  void _onEvent(String type, String? message) {
    if (type != 'message' || message == null || message.length > 700000) return;
    Map<dynamic, dynamic> packet;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map) return;
      packet = decoded;
    } catch (_) {
      return;
    }
    final kind = packet['type']?.toString();
    if (kind == 'presence') {
      _onPresence(packet);
    } else if (kind == 'presence_off') {
      final id = packet['senderId']?.toString() ?? '';
      if (_lastSeen.remove(id) != null) { _sweep(); version.value++; }
    } else if (kind == 'profile_request') {
      if (packet['recipientId']?.toString() == _myId && !ghost.value) unawaited(_answerProfileRequest(packet['senderId']?.toString() ?? ''));
    } else if (kind == 'profile_info') {
      if (packet['recipientId']?.toString() == _myId) unawaited(_onProfileInfo(packet));
    }
  }

  void _onPresence(Map<dynamic, dynamic> packet) {
    final id = packet['senderId']?.toString() ?? '';
    if (id.isEmpty || id == _myId || id.length > 200) return;
    final wasOnline = isOnline(id);
    _lastSeen[id] = DateTime.now().millisecondsSinceEpoch;
    final p = _profiles.putIfAbsent(id, () => BlousabProfile(id: id));
    final name = packet['name']?.toString() ?? '';
    if (name.trim().isNotEmpty && name.length <= 64) p.name = name.trim();
    final t1 = packet['tag1']?.toString() ?? '';
    final t2 = packet['tag2']?.toString() ?? '';
    if (t1.length <= 120) p.tag1 = t1;
    if (t2.length <= 120) p.tag2 = t2;
    p.friends = (packet['friends'] as num?)?.toInt() ?? p.friends;
    p.lastSeen = _lastSeen[id]!;
    final hash = packet['photoHash']?.toString() ?? '';
    final needPhoto = hash.isNotEmpty && (hash != p.photoHash || photoPathOf(id).isEmpty);
    if (!wasOnline) version.value++;
    _persistDir();
    if (needPhoto) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - (_lastProfileRequest[id] ?? 0) > 60000) {
        _lastProfileRequest[id] = now;
        unawaited(_send(jsonEncode({'type': 'profile_request', 'senderId': _myId, 'recipientId': id})));
      }
    }
  }

  Future<void> _answerProfileRequest(String requester) async {
    if (requester.isEmpty) return;
    final info = await _myInfo(withPhoto: true);
    await _send(jsonEncode({'type': 'profile_info', 'recipientId': requester, ...info}));
  }

  Future<void> _onProfileInfo(Map<dynamic, dynamic> packet) async {
    final id = packet['senderId']?.toString() ?? '';
    if (id.isEmpty || id == _myId) return;
    final p = _profiles.putIfAbsent(id, () => BlousabProfile(id: id));
    final name = packet['name']?.toString() ?? '';
    if (name.trim().isNotEmpty && name.length <= 64) p.name = name.trim();
    p.tag1 = packet['tag1']?.toString() ?? p.tag1;
    p.tag2 = packet['tag2']?.toString() ?? p.tag2;
    p.friends = (packet['friends'] as num?)?.toInt() ?? p.friends;
    final b64 = packet['photo']?.toString() ?? '';
    if (b64.isNotEmpty && b64.length < 500000) {
      try {
        final bytes = base64Decode(b64);
        final dir = await getApplicationDocumentsDirectory();
        final folder = Directory('${dir.path}/blousab_profiles');
        if (!await folder.exists()) await folder.create(recursive: true);
        final safe = id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
        final file = File('${folder.path}/$safe.img');
        await file.writeAsBytes(bytes, flush: true);
        await FileImage(file).evict();
        p.photoPath = file.path;
        p.photoHash = packet['photoHash']?.toString() ?? p.photoHash;
      } catch (_) {}
    }
    await _persistDir();
    version.value++;
  }

  Future<void> _persistDir() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dirKey, jsonEncode({for (final e in _profiles.entries) e.key: e.value.toJson()}));
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// عدّاد الإشعارات غير المقروءة (طلبات الصداقة + سجل الإشعارات)
// ---------------------------------------------------------------------------
class BlousabBadges {
  BlousabBadges._();
  static const String notifKey = 'blousab_notifications_v1';
  static const String notifSeenKey = 'blousab_notifications_seen_v1';
  static const String requestsKey = 'blousab_friend_requests_v1';
  static const String requestsSeenKey = 'blousab_friend_requests_seen_v1';

  static final ValueNotifier<int> unread = ValueNotifier<int>(0);

  static Future<void> refresh() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final notifTotal = (prefs.getStringList(notifKey) ?? const <String>[]).length;
      final notifSeen = prefs.getInt(notifSeenKey) ?? 0;
      final seenReq = (prefs.getStringList(requestsSeenKey) ?? const <String>[]).toSet();
      var newRequests = 0;
      for (final raw in prefs.getStringList(requestsKey) ?? const <String>[]) {
        try {
          final m = jsonDecode(raw);
          if (m is Map && !seenReq.contains(m['requestId']?.toString() ?? '')) newRequests++;
        } catch (_) {}
      }
      unread.value = (notifTotal > notifSeen ? notifTotal - notifSeen : 0) + newRequests;
    } catch (_) {}
  }

  /// عند عرض طلبات الصداقة فقط (دون سجل الإشعارات).
  static Future<void> markRequestsSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = <String>[];
      for (final raw in prefs.getStringList(requestsKey) ?? const <String>[]) {
        try {
          final m = jsonDecode(raw);
          if (m is Map) ids.add(m['requestId']?.toString() ?? '');
        } catch (_) {}
      }
      await prefs.setStringList(requestsSeenKey, ids);
    } catch (_) {}
    await refresh();
  }

  /// يُستدعى عند فتح شاشة الإشعارات: تختفي الأرقام فوراً.
  static Future<void> markAllSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final notifTotal = (prefs.getStringList(notifKey) ?? const <String>[]).length;
      await prefs.setInt(notifSeenKey, notifTotal);
      final ids = <String>[];
      for (final raw in prefs.getStringList(requestsKey) ?? const <String>[]) {
        try {
          final m = jsonDecode(raw);
          if (m is Map) ids.add(m['requestId']?.toString() ?? '');
        } catch (_) {}
      }
      await prefs.setStringList(requestsSeenKey, ids);
    } catch (_) {}
    await refresh();
  }
}

// ---------------------------------------------------------------------------
// طلبات الصداقة المشتركة بين شاشة الخلاصة وشاشة الإشعارات
// ---------------------------------------------------------------------------
class FriendRequests {
  FriendRequests._();

  static Future<List<Map<String, dynamic>>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <Map<String, dynamic>>[];
    for (final raw in prefs.getStringList(BlousabBadges.requestsKey) ?? const <String>[]) {
      try {
        final m = jsonDecode(raw);
        if (m is Map && m.isNotEmpty) out.add(Map<String, dynamic>.from(m));
      } catch (_) {}
    }
    return out;
  }

  static Future<void> _save(List<Map<String, dynamic>> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(BlousabBadges.requestsKey, list.map(jsonEncode).toList());
    QrFriendStore.changes.value++;
    await BlousabBadges.refresh();
  }

  static Future<void> add(Map<String, dynamic> request) async {
    final list = await load();
    final sender = request['senderId']?.toString() ?? '';
    if (list.any((r) => r['senderId']?.toString() == sender)) return;
    list.add(request);
    await _save(list);
  }

  static Future<void> accept(Map<String, dynamic> request, {required String myId, required String myName}) async {
    final peerId = request['senderId']?.toString() ?? '';
    if (peerId.isEmpty || peerId == myId) return;
    await QrFriendStore.addFriend(peerId);
    final list = await load();
    list.removeWhere((r) => r['requestId'] == request['requestId']);
    await _save(list);
    await BlousabPresence.instance.sendPacket(jsonEncode({
      'type': 'friend_request_response', 'requestId': request['requestId'], 'recipientId': peerId,
      'senderId': myId, 'senderName': myName, 'accepted': true,
    }));
  }

  static Future<void> reject(Map<String, dynamic> request, {required String myId, required String myName}) async {
    final peerId = request['senderId']?.toString() ?? '';
    final list = await load();
    list.removeWhere((r) => r['requestId'] == request['requestId']);
    await _save(list);
    if (peerId.isNotEmpty) {
      await BlousabPresence.instance.sendPacket(jsonEncode({
        'type': 'friend_request_response', 'requestId': request['requestId'], 'recipientId': peerId,
        'senderId': myId, 'senderName': myName, 'accepted': false,
      }));
    }
  }

  /// إرسال طلب صداقة جديد إلى مستخدم.
  static Future<bool> send({required String myId, required String myName, required String recipientId}) {
    return BlousabPresence.instance.sendPacket(jsonEncode({
      'type': 'friend_request',
      'requestId': '${myId}_${DateTime.now().microsecondsSinceEpoch}',
      'senderId': myId,
      'senderName': myName,
      'recipientId': recipientId,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    }));
  }
}
