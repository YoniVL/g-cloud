// Android TV Remote protocol v2 (Chromecast met Google TV).
// Zuiver Dart, geen Flutter-imports, zodat het ook buiten de app te testen is.
//
// Koppelen: poort 6467 (TLS + clientcertificaat), de tv toont een code van 6 tekens.
// Bedienen: poort 6466, zelfde certificaat.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

typedef AtvLog = void Function(String message);

// ------------------------------------------------------------- protobuf
/// Minimale protobuf-encoder: genoeg voor de berichten die we sturen.
class Pb {
  final BytesBuilder _b = BytesBuilder();

  void _varint(int v) {
    while (v > 0x7f) {
      _b.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _b.addByte(v);
  }

  Pb varint(int field, int v) {
    _varint(field << 3);
    _varint(v);
    return this;
  }

  Pb bytes(int field, List<int> v) {
    _varint((field << 3) | 2);
    _varint(v.length);
    _b.add(v);
    return this;
  }

  Pb str(int field, String s) => bytes(field, utf8.encode(s));
  Pb msg(int field, Pb m) => bytes(field, m.build());
  Uint8List build() => _b.toBytes();

  /// Bericht met lengteprefix (varint), zoals het protocol het verstuurt.
  Uint8List framed() {
    final body = build();
    final out = Pb().._varint(body.length);
    return Uint8List.fromList([...out.build(), ...body]);
  }
}

/// Decodeert één niveau: veldnummer -> lijst van waarden (int of Uint8List).
Map<int, List<Object>> pbDecode(Uint8List d) {
  final out = <int, List<Object>>{};
  var i = 0;
  int readVarint() {
    var shift = 0, v = 0;
    while (true) {
      final b = d[i++];
      v |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return v;
      shift += 7;
    }
  }

  while (i < d.length) {
    final tag = readVarint();
    final field = tag >> 3;
    switch (tag & 7) {
      case 0:
        (out[field] ??= []).add(readVarint());
      case 2:
        final len = readVarint();
        (out[field] ??= []).add(Uint8List.sublistView(d, i, i + len));
        i += len;
      case 1:
        i += 8;
      case 5:
        i += 4;
      default:
        throw FormatException('Onbekend wiretype ${tag & 7}');
    }
  }
  return out;
}

Uint8List? _sub(Map<int, List<Object>> m, int field) {
  final v = m[field];
  return (v == null || v.isEmpty || v.first is! Uint8List) ? null : v.first as Uint8List;
}

int? _int(Map<int, List<Object>> m, int field) {
  final v = m[field];
  return (v == null || v.isEmpty || v.first is! int) ? null : v.first as int;
}

/// Leest berichten met lengteprefix uit een socket.
class _Messages {
  final _buf = <int>[];
  final _queue = <Map<int, List<Object>>>[];
  final _waiters = <Completer<Map<int, List<Object>>?>>[];
  bool _closed = false;

  _Messages(Stream<Uint8List> s) {
    s.listen((chunk) {
      _buf.addAll(chunk);
      while (true) {
        var i = 0, shift = 0, len = 0;
        var complete = false;
        while (i < _buf.length) {
          final b = _buf[i++];
          len |= (b & 0x7f) << shift;
          shift += 7;
          if (b & 0x80 == 0) {
            complete = true;
            break;
          }
        }
        if (!complete || _buf.length < i + len) return;
        final body = Uint8List.fromList(_buf.sublist(i, i + len));
        _buf.removeRange(0, i + len);
        final m = pbDecode(body);
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(m);
        } else {
          _queue.add(m);
        }
      }
    }, onDone: _close, onError: (_) => _close());
  }

  void _close() {
    _closed = true;
    for (final w in _waiters) {
      w.complete(null);
    }
    _waiters.clear();
  }

  Future<Map<int, List<Object>>?> next([Duration timeout = const Duration(seconds: 10)]) {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    if (_closed) return Future.value(null);
    final c = Completer<Map<int, List<Object>>?>();
    _waiters.add(c);
    return c.future.timeout(timeout, onTimeout: () {
      _waiters.remove(c);
      return null;
    });
  }
}

// ------------------------------------------------------------- certificaat
/// Ons eigen clientcertificaat. De tv onthoudt het na het koppelen.
class AtvCredentials {
  final String certPem;
  final String keyPem;
  const AtvCredentials(this.certPem, this.keyPem);

  /// RSA 2048 genereren duurt even; doe het in een aparte isolate.
  static Future<AtvCredentials> generate() => Isolate.run(() {
        final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
        final priv = pair.privateKey as RSAPrivateKey;
        final pub = pair.publicKey as RSAPublicKey;
        final csr = X509Utils.generateRsaCsrPem(
            {'CN': 'g-cloud-launcher', 'O': 'G Cloud', 'C': 'BE'}, priv, pub);
        final cert = X509Utils.generateSelfSignedCertificate(priv, csr, 3650);
        return AtvCredentials(cert, CryptoUtils.encodeRSAPrivateKeyToPemPkcs1(priv));
      });
}

({BigInt n, BigInt e}) _rsaFromCert(List<int> der) {
  final pem = '-----BEGIN CERTIFICATE-----\n${base64.encode(der)}\n-----END CERTIFICATE-----';
  final info = X509Utils.x509CertificateFromPem(pem).tbsCertificate!.subjectPublicKeyInfo;
  final hex = info.bytes!.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final bytes = Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)
  ]);
  final key = CryptoUtils.rsaPublicKeyFromDERBytes(bytes);
  return (n: key.modulus!, e: key.exponent!);
}

List<int> _bigBytes(BigInt v) {
  var hex = v.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  return [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
}

Future<SecureSocket> _connect(String host, int port, AtvCredentials c) {
  final ctx = SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(c.certPem))
    ..usePrivateKeyBytes(utf8.encode(c.keyPem));
  return SecureSocket.connect(host, port,
      context: ctx, onBadCertificate: (_) => true, timeout: const Duration(seconds: 8));
}

// ------------------------------------------------------------- koppelen
/// Koppelen in twee stappen: [start] laat de tv de code tonen, [finish] bevestigt hem.
class AtvPairing {
  final String host;
  final AtvCredentials creds;
  final AtvLog log;
  AtvPairing(this.host, this.creds, this.log);

  SecureSocket? _socket;
  _Messages? _in;
  late List<int> _clientN, _clientE, _serverN, _serverE;

  Uint8List _pairing(Pb Function(Pb) body) =>
      body(Pb().varint(1, 2).varint(2, 200)).framed(); // protocol_version=2, status OK

  Future<Map<int, List<Object>>> _expect(int field, String what) async {
    final m = await _in!.next();
    if (m == null) throw StateError('Geen antwoord van de tv bij: $what');
    final status = _int(m, 2);
    if (status != null && status != 200) throw StateError('Tv weigert ($what), status $status');
    if (!m.containsKey(field)) throw StateError('Onverwacht antwoord bij: $what');
    return m;
  }

  Future<void> start() async {
    final s = await _connect(host, 6467, creds);
    _socket = s;
    _in = _Messages(s);

    final server = _rsaFromCert(s.peerCertificate!.der);
    final client = _rsaFromCert(
        base64.decode(creds.certPem.replaceAll(RegExp(r'-----[A-Z ]+-----|\s'), '')));
    _serverN = _bigBytes(server.n);
    _serverE = _bigBytes(server.e);
    _clientN = _bigBytes(client.n);
    _clientE = _bigBytes(client.e);

    s.add(_pairing((p) => p.msg(
        10, Pb().str(1, 'androidtv-remote').str(2, 'G Cloud launcher'))));
    await _expect(11, 'koppelverzoek');
    log('Tv accepteert het koppelverzoek');

    const hex = 3, inputRole = 1;
    s.add(_pairing((p) => p.msg(
        20, Pb().msg(1, Pb().varint(1, hex).varint(2, 6)).varint(3, inputRole))));
    await _expect(20, 'opties');

    s.add(_pairing((p) => p.msg(
        30, Pb().msg(1, Pb().varint(1, hex).varint(2, 6)).varint(2, inputRole))));
    await _expect(31, 'configuratie');
    log('Kijk op de tv: er staat een code van 6 tekens');
  }

  /// [code] is de code van de tv (hex, 6 tekens).
  Future<void> finish(String code) async {
    final s = _socket;
    if (s == null) throw StateError('Eerst koppelen starten');
    final clean = code.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(clean)) {
      throw const FormatException('De code bestaat uit 6 tekens (0-9 en A-F)');
    }
    final codeBytes = [for (var i = 0; i < 6; i += 2) int.parse(clean.substring(i, i + 2), radix: 16)];
    final hash = sha256
        .convert([..._clientN, ..._clientE, ..._serverN, ..._serverE, ...codeBytes.sublist(1)])
        .bytes;
    if (hash[0] != codeBytes[0]) {
      throw const FormatException('Code klopt niet (controlegetal), typfout?');
    }
    s.add(_pairing((p) => p.msg(40, Pb().bytes(1, hash))));
    await _expect(41, 'code');
    log('Gekoppeld');
    await close();
  }

  Future<void> close() async {
    await _socket?.close();
    _socket = null;
  }
}

// ------------------------------------------------------------- bedienen
class AtvKey {
  static const home = 3, back = 4, up = 19, down = 20, left = 21, right = 22, center = 23;
  static const power = 26, playPause = 85, menu = 82;
}

class AtvRemote {
  final String host;
  final AtvCredentials creds;
  final AtvLog log;
  AtvRemote(this.host, this.creds, this.log);

  SecureSocket? _socket;
  String? currentApp;
  final _appController = StreamController<String>.broadcast();
  Stream<String> get appChanges => _appController.stream;
  bool get connected => _socket != null;

  Future<void> connect() async {
    final s = await _connect(host, 6466, creds);
    _socket = s;
    final inbox = _Messages(s);
    var active = false;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!active && DateTime.now().isBefore(deadline)) {
      final m = await inbox.next();
      if (m == null) break;
      active = _handle(s, m);
    }
    if (!active) {
      await close();
      throw StateError('Tv gaf geen actieve verbinding. Is hij gekoppeld?');
    }
    _listen(s, inbox);
  }

  void _listen(SecureSocket s, _Messages inbox) async {
    while (true) {
      final m = await inbox.next(const Duration(minutes: 5));
      if (m == null) break;
      _handle(s, m);
    }
    if (identical(_socket, s)) {
      _socket = null;
      log('Verbinding met de tv verbroken');
    }
  }

  /// Verwerkt een bericht van de tv. Geeft true zodra de verbinding actief is.
  bool _handle(SecureSocket s, Map<int, List<Object>> m) {
    var active = false;
    final configure = _sub(m, 1);
    if (configure != null) {
      // Zonder dit antwoord praat de tv niet verder.
      s.add(Pb()
          .msg(
              1,
              Pb().varint(1, 622).msg(
                  2,
                  Pb()
                      .str(1, 'G Cloud')
                      .str(2, 'Logitech')
                      .varint(3, 1)
                      .str(4, '1')
                      .str(5, 'androidtv-remote')
                      .str(6, '1.0.0')))
          .framed());
    }
    if (_sub(m, 2) != null) {
      s.add(Pb().msg(2, Pb().varint(1, 622)).framed());
      active = true;
    }
    final ping = _sub(m, 8);
    if (ping != null) {
      final v = _int(pbDecode(ping), 1) ?? 0;
      s.add(Pb().msg(9, Pb().varint(1, v)).framed());
    }
    final ime = _sub(m, 20);
    if (ime != null) {
      final appInfo = _sub(pbDecode(ime), 1);
      final pkg = appInfo == null ? null : _sub(pbDecode(appInfo), 12);
      if (pkg != null) {
        currentApp = utf8.decode(pkg);
        _appController.add(currentApp!);
      }
    }
    if (_sub(m, 3) != null) log('Tv meldt een fout');
    return active;
  }

  void _send(Pb p) {
    final s = _socket;
    if (s == null) throw StateError('Niet verbonden met de tv');
    s.add(p.framed());
  }

  /// Korte druk op een toets (Android-keycode).
  void key(int keyCode) => _send(Pb().msg(10, Pb().varint(1, keyCode).varint(2, 3)));

  /// Start een app via pakketnaam (market://launch?id=...) of een eigen link.
  void launch(String packageOrLink) {
    final link = packageOrLink.contains(':') ? packageOrLink : 'market://launch?id=$packageOrLink';
    _send(Pb().msg(90, Pb().str(1, link)));
  }

  Future<void> close() async {
    final s = _socket;
    _socket = null;
    await s?.close();
  }
}
