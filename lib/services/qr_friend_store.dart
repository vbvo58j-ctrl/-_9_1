import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// تخزين مشترك للأصدقاء الذين يُضافون عبر مسح رمز QR (اتصال مباشر دون طلب صداقة).
class QrFriendStore {
  QrFriendStore._();

  static const String friendsKey = 'blousab_accepted_friends_v1';
  static const String tokenKey = 'blousab_qr_token_v1';
  static const String pendingKey = 'blousab_qr_pending_v1';

  /// يزداد كلما تغيّرت قائمة الأصدقاء ليعيد المستمعون تحميلها.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// رمز سري عشوائي يظهر داخل QR الخاص بي؛ لا يُقبل الاتصال إلا لمن مسح الرمز فعلاً.
  static Future<String> myToken() async {
    final prefs = await SharedPreferences.getInstance();
    var token = prefs.getString(tokenKey) ?? '';
    if (token.length < 16) {
      final rnd = Random.secure();
      token = List<String>.generate(24, (_) => rnd.nextInt(16).toRadixString(16)).join();
      await prefs.setString(tokenKey, token);
    }
    return token;
  }

  static Future<bool> isTokenValid(String? token) async {
    if (token == null || token.isEmpty) return false;
    return token == await myToken();
  }

  /// يضيف صديقاً مباشرة. يعيد true إذا لم يكن موجوداً من قبل.
  static Future<bool> addFriend(String id) async {
    if (id.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    final friends = (prefs.getStringList(friendsKey) ?? <String>[]).toSet();
    final added = friends.add(id);
    if (added) {
      await prefs.setStringList(friendsKey, friends.toList());
      changes.value++;
    }
    return added;
  }

  static Future<Set<String>> loadFriends() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(friendsKey) ?? <String>[]).toSet();
  }

  // ----- إشعارات الاتصال التي لم يؤكد الطرف الآخر استلامها بعد -----

  static Future<List<Map<String, dynamic>>> loadPending() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <Map<String, dynamic>>[];
    for (final item in prefs.getStringList(pendingKey) ?? <String>[]) {
      try {
        final map = Map<String, dynamic>.from(jsonDecode(item) as Map);
        final created = (map['createdAt'] as num?)?.toInt() ?? 0;
        if (now - created < const Duration(days: 7).inMilliseconds) out.add(map);
      } catch (_) {}
    }
    return out;
  }

  static Future<void> _savePending(List<Map<String, dynamic>> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(pendingKey, list.map(jsonEncode).toList());
  }

  static Future<void> addPending(Map<String, dynamic> packet) async {
    final list = await loadPending();
    list.removeWhere((p) => p['recipientId'] == packet['recipientId']);
    list.add(packet);
    await _savePending(list);
  }

  static Future<void> removePending(String recipientId) async {
    final list = await loadPending();
    list.removeWhere((p) => p['recipientId'] == recipientId);
    await _savePending(list);
  }
}
