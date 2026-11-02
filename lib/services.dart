import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

double asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse('${v ?? ''}') ?? 0;
}

/// 1234567.8 -> "1,234,568" (or with [decimals] places).
String fmtNum(double v, {int decimals = 0}) {
  final parts = v.toStringAsFixed(decimals).split('.');
  final digits = parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final fromEnd = digits.length - i;
    buf.write(digits[i]);
    if (fromEnd > 1 && fromEnd % 3 == 1) buf.write(',');
  }
  return decimals > 0 ? '$buf.${parts[1]}' : buf.toString();
}

// ---------------------------------------------------------------------------
// Account (Supabase Auth over REST)
// ---------------------------------------------------------------------------

class AuthException implements Exception {
  final String message;
  final int status;
  AuthException(this.message, [this.status = 0]);

  @override
  String toString() => message;
}

class AuthSession {
  final String accessToken;
  final String refreshToken;
  final int expiresAt;
  final String userId;
  final String email;

  AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.userId,
    required this.email,
  });

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt,
        'user_id': userId,
        'email': email,
      };

  factory AuthSession.fromJson(Map<String, dynamic> j) => AuthSession(
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        expiresAt: (j['expires_at'] as num).toInt(),
        userId: j['user_id'] as String,
        email: (j['email'] ?? '') as String,
      );
}

class AuthService {
  static final ValueNotifier<AuthSession?> session = ValueNotifier<AuthSession?>(null);
  static late SharedPreferences prefs;
  static Future<void>? _refreshing;

  // Tokens live in the Android Keystore-backed encrypted store, never in plain prefs.
  static const FlutterSecureStorage _vault = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const String _vaultKey = 'auth_session';

  static Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_session'); // older builds kept the session here
    try {
      final raw = await _vault.read(key: _vaultKey);
      if (raw == null) return;
      session.value = AuthSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Unreadable or corrupt: start signed out rather than crash.
      try {
        await _vault.deleteAll();
      } catch (_) {}
    }
  }

  static Future<void> _forget() async {
    session.value = null;
    try {
      await _vault.delete(key: _vaultKey);
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    String? bearer,
  }) async {
    final uri = Uri.parse('${AppConfig.supabaseUrl}/auth/v1$path');
    try {
      final resp = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'apikey': AppConfig.supabaseAnonKey,
              if (bearer != null) 'Authorization': 'Bearer $bearer',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
      dynamic decoded;
      try {
        decoded = resp.bodyBytes.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(resp.bodyBytes));
      } catch (_) {
        decoded = <String, dynamic>{};
      }
      final Map<String, dynamic> map = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw AuthException(_friendly(map, resp.statusCode), resp.statusCode);
      }
      return map;
    } on AuthException {
      rethrow;
    } on TimeoutException {
      throw AuthException('The connection timed out. Check your network and try again.');
    } catch (_) {
      throw AuthException('Can\'t reach the server. Check your network and try again.');
    }
  }

  static String _friendly(Map<String, dynamic> m, int status) {
    final code = '${m['error_code'] ?? m['error'] ?? ''}';
    final msg = '${m['msg'] ?? m['error_description'] ?? m['message'] ?? ''}';
    switch (code) {
      case 'invalid_credentials':
      case 'invalid_grant':
        return msg.toLowerCase().contains('confirm')
            ? 'Confirm your email first. The link is in your inbox.'
            : 'That email and password don\'t match.';
      case 'email_not_confirmed':
        return 'Confirm your email first. The link is in your inbox.';
      case 'user_already_exists':
      case 'email_exists':
        return 'An account with this email already exists. Log in instead.';
      case 'weak_password':
        return msg.isNotEmpty ? msg : 'Choose a stronger password.';
      case 'over_request_rate_limit':
      case 'over_email_send_rate_limit':
        return 'Too many attempts. Wait a few minutes and try again.';
      case 'signup_disabled':
        return 'New accounts are closed right now.';
    }
    return msg.isNotEmpty ? msg : 'Something went wrong (error $status).';
  }

  static Future<void> _store(Map<String, dynamic> j) async {
    final user = j['user'] is Map<String, dynamic> ? j['user'] as Map<String, dynamic> : <String, dynamic>{};
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiresAt = j['expires_at'] is num
        ? (j['expires_at'] as num).toInt()
        : nowSec + ((j['expires_in'] as num?)?.toInt() ?? 3600);
    final s = AuthSession(
      accessToken: j['access_token'] as String,
      refreshToken: j['refresh_token'] as String,
      expiresAt: expiresAt,
      userId: (user['id'] ?? session.value?.userId ?? '') as String,
      email: (user['email'] ?? session.value?.email ?? '') as String,
    );
    await _vault.write(key: _vaultKey, value: jsonEncode(s.toJson()));
    session.value = s;
  }

  /// Returns true when the account is signed in immediately, false when the
  /// project requires email confirmation first.
  static Future<bool> signUp(String email, String password) async {
    final j = await _post('/signup', {'email': email, 'password': password});
    if (j['access_token'] != null) {
      await _store(j);
      return true;
    }
    return false;
  }

  static Future<void> signIn(String email, String password) async {
    final j = await _post('/token?grant_type=password', {'email': email, 'password': password});
    await _store(j);
  }

  static Future<void> sendReset(String email) => _post('/recover', {'email': email});

  static Future<void> signOut() async {
    final s = session.value;
    await _forget();
    if (s != null) {
      try {
        await _post('/logout', <String, dynamic>{}, bearer: s.accessToken);
      } catch (_) {
        // best effort
      }
    }
  }

  static Future<void> _refresh(String refreshToken) async {
    try {
      final j = await _post('/token?grant_type=refresh_token', {'refresh_token': refreshToken});
      await _store(j);
    } on AuthException catch (e) {
      // 4xx means the refresh token is dead; network errors keep the session.
      if (e.status >= 400 && e.status < 500) {
        await _forget();
      }
      rethrow;
    }
  }

  static Future<String?> accessToken() async {
    final s = session.value;
    if (s == null) return null;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (s.expiresAt - nowSec > 60) return s.accessToken;
    _refreshing ??= _refresh(s.refreshToken).whenComplete(() => _refreshing = null);
    try {
      await _refreshing;
    } catch (_) {
      // fall through with whatever session remains
    }
    return session.value?.accessToken;
  }
}

/// Per-account flags kept on the device.
class LocalState {
  static String get _uid => AuthService.session.value?.userId ?? 'anon';

  static bool get optedIn => AuthService.prefs.getBool('opted_in_$_uid') ?? false;
  static Future<void> setOptedIn(bool v) => AuthService.prefs.setBool('opted_in_$_uid', v);

  static int get lastBytes => AuthService.prefs.getInt('last_bytes_$_uid') ?? 0;
  static Future<void> setLastBytes(int v) => AuthService.prefs.setInt('last_bytes_$_uid', v);

  // A report that was sent but not answered yet. Retrying it with the SAME id means the
  // server can never count it twice, and a dropped connection never loses it.
  static String? get pendingId => _pending()?[0];
  static double get pendingMb => double.tryParse(_pending()?[1] ?? '') ?? 0;

  static List<String>? _pending() {
    final raw = AuthService.prefs.getString('pending_report_$_uid');
    if (raw == null) return null;
    final parts = raw.split('|');
    if (parts.length != 3) return null;
    final at = int.tryParse(parts[2]) ?? 0;
    // The server drops unanswered reports after 30 minutes, so do the same here.
    if (DateTime.now().millisecondsSinceEpoch - at > 45 * 60 * 1000) return null;
    return parts;
  }

  static Future<void> setPending(String id, double mb) => AuthService.prefs
      .setString('pending_report_$_uid', '$id|$mb|${DateTime.now().millisecondsSinceEpoch}');
  static Future<void> clearPending() => AuthService.prefs.remove('pending_report_$_uid');

  static String newReportId() {
    final rnd = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return 'r${List<String>.generate(23, (_) => chars[rnd.nextInt(chars.length)]).join()}';
  }
}

/// Copies a gift-card code and wipes the clipboard a minute later (the timer is static,
/// so it still fires after the screen that started it is gone).
class SecretClipboard {
  static Timer? _timer;

  static Future<void> copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 60), () {
      Clipboard.setData(const ClipboardData(text: ''));
    });
  }
}

// ---------------------------------------------------------------------------
// Native node bridge (MethodChannel -> MysteriumNodeService)
// ---------------------------------------------------------------------------

class NodeChannel {
  static const MethodChannel _channel = MethodChannel(AppConfig.channelName);

  static Future<bool> start() async {
    final ok = await _channel.invokeMethod<bool>('startNode');
    if (ok != true) return false;
    try {
      await ProxyChannel.start();
      return true;
    } catch (_) {
      try {
        await _channel.invokeMethod<bool>('stopNode');
      } catch (_) {}
      rethrow;
    }
  }

  static Future<void> stop() async {
    await ProxyChannel.stop();
    await _channel.invokeMethod<bool>('stopNode');
  }

  static Future<bool> isRunning() async {
    final running = await _channel.invokeMethod<bool>('isRunning');
    return running ?? false;
  }

  /// Cumulative real bytes transmitted since the node started.
  static Future<int> getBytesShared() async {
    final bytes = await _channel.invokeMethod<int>('getBytesShared');
    return bytes ?? 0;
  }

  static Future<Map<String, dynamic>> status() async {
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('getStatus');
    return Map<String, dynamic>.from(res ?? <dynamic, dynamic>{});
  }
}

// ---------------------------------------------------------------------------
// Backend API
// ---------------------------------------------------------------------------

class ApiException implements Exception {
  final int status;
  final String message;
  final String code;
  ApiException(this.status, this.message, [this.code = '']);

  @override
  String toString() => message;
}

String _friendlyApi(String code, int status) {
  switch (code) {
    case 'email_unconfirmed':
      return 'Confirm your email first. The link is in your inbox.';
    case 'account_frozen':
    case 'account_blocked':
      return 'This account is on hold. Contact support.';
    case 'not_opted_in':
      return 'Turn sharing on first.';
    case 'insufficient_points':
      return 'You don\'t have enough spendable points yet. New points unlock after a 24-hour hold.';
    case 'daily_limit':
      return 'You\'ve reached today\'s limit. Try again tomorrow.';
    case 'store_busy':
      return 'The store is busy right now. Try again later.';
    case 'too_frequent':
      return 'Slow down a little. Try again in a minute.';
    case 'catalog_unavailable':
    case 'product_unavailable':
      return 'That item isn\'t available right now.';
    case 'invalid_selection':
      return 'Pick one of the listed amounts.';
    case 'payout_failed':
      return 'The gift card order failed. Your points were returned.';
    case 'payout_unknown':
      return 'The order status is unclear. Check Your gift cards in a few minutes before trying again.';
    case 'auditor_unavailable':
      return 'The verifier is busy. We\'ll retry automatically.';
  }
  return 'Something went wrong (error $status). Try again.';
}

class Pkg {
  final String? id;
  final double value;
  Pkg(this.id, this.value);
}

class Product {
  final String id;
  final String name;
  final String? image;
  final String? currency;
  final List<Pkg> packages;
  final double? min;
  final double? max;
  final double? step;

  Product({
    required this.id,
    required this.name,
    required this.image,
    required this.currency,
    required this.packages,
    required this.min,
    required this.max,
    required this.step,
  });

  factory Product.fromJson(Map<String, dynamic> j) {
    final pk = <Pkg>[];
    final rawPk = j['packages'];
    if (rawPk is List) {
      for (final e in rawPk) {
        if (e is Map) pk.add(Pkg(e['package_id']?.toString(), asDouble(e['value'])));
      }
    }
    double? mn;
    double? mx;
    double? st;
    final r = j['range'];
    if (r is Map) {
      mn = asDouble(r['min']);
      mx = asDouble(r['max']);
      final s = asDouble(r['step']);
      st = s > 0 ? s : 1.0;
    }
    return Product(
      id: j['id'].toString(),
      name: (j['name'] ?? j['id']).toString(),
      image: j['image']?.toString(),
      currency: j['currency']?.toString(),
      packages: pk,
      min: mn,
      max: mx,
      step: st,
    );
  }
}

class Api {
  static final http.Client _client = http.Client();

  static Future<http.Response> _request(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
    Duration timeout,
  ) async {
    try {
      if (method == 'GET') {
        return await _client.get(uri, headers: headers).timeout(timeout);
      }
      return await _client
          .post(uri, headers: headers, body: jsonEncode(body ?? <String, dynamic>{}))
          .timeout(timeout);
    } on TimeoutException {
      throw ApiException(0, 'The request timed out. Try again.');
    } catch (_) {
      throw ApiException(0, 'Can\'t reach the server. Check your network.');
    }
  }

  static Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final token = await AuthService.accessToken();
    if (token == null) throw ApiException(401, 'Log in to continue.');

    final uri = Uri.parse('${AppConfig.apiBase}$path').replace(queryParameters: query);
    final resp = await _request(
      method,
      uri,
      {
        'Content-Type': 'application/json',
        'x-app-key': AppConfig.appKey,
        'Authorization': 'Bearer $token',
      },
      body,
      timeout,
    );

    dynamic decoded;
    try {
      decoded = resp.bodyBytes.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(resp.bodyBytes));
    } catch (_) {
      decoded = <String, dynamic>{};
    }
    final Map<String, dynamic> map = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};

    if (resp.statusCode == 401) {
      await AuthService.signOut();
      throw ApiException(401, 'Your session expired. Log in again.');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final code = '${map['error'] ?? ''}';
      throw ApiException(resp.statusCode, _friendlyApi(code, resp.statusCode), code);
    }
    map['_status'] = resp.statusCode;
    return map;
  }

  static Future<Map<String, dynamic>> consent(bool optedIn) =>
      _send('POST', '/api/consent', body: {'opted_in': optedIn});

  static Future<Map<String, dynamic>> heartbeat() => _send('POST', '/api/heartbeat');

  static Future<Map<String, dynamic>> ledger() => _send('GET', '/api/ledger');

  static Future<Map<String, dynamic>> verifyBandwidth(double mb, String reportId) =>
      _send('POST', '/api/verify-bandwidth', body: {'mb_shared': mb, 'report_id': reportId});

  static Future<List<Product>> catalog(String country) async {
    final j = await _send('GET', '/api/get-catalog', query: {'country': country});
    final raw = j['products'];
    if (raw is! List) return <Product>[];
    return raw.whereType<Map<String, dynamic>>().map(Product.fromJson).toList();
  }

  static Future<Map<String, dynamic>> redeem(String productId, String? packageId, double value) {
    final body = <String, dynamic>{'product_id': productId, 'value': value};
    if (packageId != null) body['package_id'] = packageId;
    return _send('POST', '/api/redeem', body: body, timeout: const Duration(seconds: 75));
  }
}
