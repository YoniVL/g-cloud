import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chromecast.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'G Cloud probe',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const Home(),
      );
}

/// Gedeeld logboek: alles wat we proberen komt hier in te staan.
final ValueNotifier<List<String>> logLines = ValueNotifier([]);
void log(String s) {
  final t = TimeOfDay.now();
  final stamp =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  logLines.value = ['$stamp  $s', ...logLines.value].take(60).toList();
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    const pages = [KeysPage(), HuePage(), SonosPage(), ChromecastPage()];
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(child: pages[tab]),
          SizedBox(
            height: 90,
            child: ValueListenableBuilder<List<String>>(
              valueListenable: logLines,
              builder: (_, l, __) => ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [for (final s in l) Text(s, style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))],
              ),
            ),
          ),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.gamepad), label: 'Knoppen'),
          NavigationDestination(icon: Icon(Icons.lightbulb), label: 'Hue'),
          NavigationDestination(icon: Icon(Icons.speaker), label: 'Sonos'),
          NavigationDestination(icon: Icon(Icons.tv), label: 'Chromecast'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- Knoppen
/// Druk op de G-knop (en alle andere knoppen) en kijk of Android ze doorgeeft.
class KeysPage extends StatefulWidget {
  const KeysPage({super.key});
  @override
  State<KeysPage> createState() => _KeysPageState();
}

class _KeysPageState extends State<KeysPage> {
  String last = 'Druk op een knop, vooral de G-knop rechtsonder';
  final node = FocusNode();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => node.requestFocus());
  }

  @override
  Widget build(BuildContext context) => Focus(
        focusNode: node,
        autofocus: true,
        onKeyEvent: (n, e) {
          if (e is KeyDownEvent) {
            final msg =
                '${e.logicalKey.keyLabel.isEmpty ? e.logicalKey.debugName : e.logicalKey.keyLabel} '
                '| logical ${e.logicalKey.keyId.toRadixString(16)} '
                '| physical ${e.physicalKey.usbHidUsage.toRadixString(16)}';
            setState(() => last = msg);
            log('KEY $msg');
          }
          return KeyEventResult.handled;
        },
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(last, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20)),
          ),
        ),
      );
}

// ---------------------------------------------------------------- Hue
class HuePage extends StatefulWidget {
  const HuePage({super.key});
  @override
  State<HuePage> createState() => _HuePageState();
}

class _HuePageState extends State<HuePage> {
  final ip = TextEditingController();
  String? key;
  List<Map<String, String>> scenes = [];

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      ip.text = p.getString('hue_ip') ?? '';
      key = p.getString('hue_key');
      setState(() {});
    });
  }

  HttpClient _client() =>
      HttpClient()..badCertificateCallback = (cert, host, port) => true; // bridge heeft een eigen certificaat

  Future<String> _send(String method, String path, {String? body}) async {
    final c = _client();
    final req = await c.openUrl(method, Uri.parse('https://${ip.text.trim()}$path'));
    if (key != null) req.headers.set('hue-application-key', key!);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    c.close();
    return text;
  }

  Future<void> pair() async {
    try {
      final text = await _send('POST', '/api',
          body: jsonEncode({'devicetype': 'gcloud_probe#gcloud', 'generateclientkey': true}));
      final data = jsonDecode(text);
      final ok = data is List && data.isNotEmpty ? data[0]['success'] : null;
      if (ok == null) {
        log('Hue koppelen: druk eerst op de knop op de bridge en probeer opnieuw. ($text)');
        return;
      }
      key = ok['username'] as String;
      final p = await SharedPreferences.getInstance();
      await p.setString('hue_ip', ip.text.trim());
      await p.setString('hue_key', key!);
      log('Hue gekoppeld.');
      setState(() {});
    } catch (e) {
      log('Hue fout: $e');
    }
  }

  Future<void> loadScenes() async {
    try {
      final text = await _send('GET', '/clip/v2/resource/scene');
      final data = jsonDecode(text)['data'] as List;
      scenes = [for (final s in data) {'id': s['id'] as String, 'name': (s['metadata']?['name'] ?? '?') as String}];
      log('Hue: ${scenes.length} scenes gevonden.');
      setState(() {});
    } catch (e) {
      log('Hue fout: $e');
    }
  }

  Future<void> recall(String id, String name) async {
    try {
      final text = await _send('PUT', '/clip/v2/resource/scene/$id',
          body: jsonEncode({'recall': {'action': 'active'}}));
      log('Hue scene "$name": $text');
    } catch (e) {
      log('Hue fout: $e');
    }
  }

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: ip, decoration: const InputDecoration(labelText: 'IP-adres van de Hue bridge')),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton(onPressed: pair, child: const Text('Koppel (druk eerst op de bridge)')),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: key == null ? null : loadScenes, child: const Text('Scenes laden')),
        ]),
        const SizedBox(height: 8),
        Text(key == null ? 'Nog niet gekoppeld' : 'Gekoppeld'),
        for (final s in scenes)
          ListTile(title: Text(s['name']!), onTap: () => recall(s['id']!, s['name']!)),
      ]);
}

// ---------------------------------------------------------------- Sonos
class SonosPage extends StatefulWidget {
  const SonosPage({super.key});
  @override
  State<SonosPage> createState() => _SonosPageState();
}

class _SonosPageState extends State<SonosPage> {
  final ip = TextEditingController();
  double volume = 20;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      ip.text = p.getString('sonos_ip') ?? '';
      setState(() {});
    });
  }

  Future<String> _soap(String path, String service, String action, String args) async {
    final c = HttpClient();
    final req = await c.postUrl(Uri.parse('http://${ip.text.trim()}:1400$path'));
    req.headers.set('SOAPACTION', '"urn:schemas-upnp-org:service:$service:1#$action"');
     final bytes = utf8.encode('<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        '<u:$action xmlns:u="urn:schemas-upnp-org:service:$service:1">$args</u:$action>'
        '</s:Body></s:Envelope>');
    req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    c.close();
    final p = await SharedPreferences.getInstance();
    await p.setString('sonos_ip', ip.text.trim());
    return text;
  }

  Future<void> transport(String action) async {
    try {
      final r = await _soap('/MediaRenderer/AVTransport/Control', 'AVTransport', action,
          '<InstanceID>0</InstanceID>${action == 'Play' ? '<Speed>1</Speed>' : ''}');
      log('Sonos $action: ${r.contains('Fault') ? 'FOUT $r' : 'ok'}');
    } catch (e) {
      log('Sonos fout: $e');
    }
  }

  Future<void> state() async {
    try {
      final r = await _soap('/MediaRenderer/AVTransport/Control', 'AVTransport', 'GetTransportInfo',
          '<InstanceID>0</InstanceID>');
      final m = RegExp(r'<CurrentTransportState>(.*?)</CurrentTransportState>').firstMatch(r);
      final pos = await _soap('/MediaRenderer/AVTransport/Control', 'AVTransport', 'GetPositionInfo',
          '<InstanceID>0</InstanceID>');
      final uri = RegExp(r'<TrackURI>(.*?)</TrackURI>').firstMatch(pos)?.group(1) ?? '';
      log('Sonos status: ${m?.group(1)}  bron: ${uri.split('?').first}');
      final v = await _soap('/MediaRenderer/RenderingControl/Control', 'RenderingControl', 'GetVolume',
          '<InstanceID>0</InstanceID><Channel>Master</Channel>');
      final vol = RegExp(r'<CurrentVolume>(\d+)</CurrentVolume>').firstMatch(v)?.group(1);
      if (vol != null) setState(() => volume = double.parse(vol));
    } catch (e) {
      log('Sonos fout: $e');
    }
  }

  Future<void> setVolume(double v) async {
    try {
      await _soap('/MediaRenderer/RenderingControl/Control', 'RenderingControl', 'SetVolume',
          '<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>${v.round()}</DesiredVolume>');
      log('Sonos volume ${v.round()}');
    } catch (e) {
      log('Sonos fout: $e');
    }
  }

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: ip, decoration: const InputDecoration(labelText: 'IP-adres van de Beam')),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          FilledButton(onPressed: state, child: const Text('Status')),
          FilledButton(onPressed: () => transport('Play'), child: const Text('Play')),
          FilledButton(onPressed: () => transport('Pause'), child: const Text('Pauze')),
          FilledButton(onPressed: () => transport('Next'), child: const Text('Volgende')),
        ]),
        const SizedBox(height: 16),
        Text('Volume ${volume.round()}'),
        Slider(
          value: volume,
          min: 0,
          max: 100,
          onChanged: (v) => setState(() => volume = v),
          onChangeEnd: setVolume,
        ),
      ]);
}


// ---------------------------------------------------------------- Chromecast
class ChromecastPage extends StatefulWidget {
  const ChromecastPage({super.key});
  @override
  State<ChromecastPage> createState() => _ChromecastPageState();
}

class _ChromecastPageState extends State<ChromecastPage> {
  final ip = TextEditingController();
  final code = TextEditingController();
  final pkg = TextEditingController();
  AtvCredentials? creds;
  AtvPairing? pairing;
  AtvRemote? remote;
  bool awaitingCode = false;
  bool busy = false;
  String app = '-';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      ip.text = p.getString('atv_ip') ?? '';
      final c = p.getString('atv_cert'), k = p.getString('atv_key');
      if (c != null && k != null) creds = AtvCredentials(c, k);
      setState(() {});
    });
  }

  @override
  void dispose() {
    remote?.close();
    pairing?.close();
    super.dispose();
  }

  Future<void> run(String what, Future<void> Function() f) async {
    setState(() => busy = true);
    try {
      await f();
    } catch (e) {
      log('Chromecast $what: FOUT $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> saveIp() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('atv_ip', ip.text.trim());
  }

  Future<void> startPairing() => run('koppelen', () async {
        await saveIp();
        if (creds == null) {
          log('Sleutel maken, dit duurt even...');
          creds = await AtvCredentials.generate();
          final p = await SharedPreferences.getInstance();
          await p.setString('atv_cert', creds!.certPem);
          await p.setString('atv_key', creds!.keyPem);
        }
        await pairing?.close();
        pairing = AtvPairing(ip.text.trim(), creds!, (m) => log('Chromecast: $m'));
        await pairing!.start();
        setState(() => awaitingCode = true);
      });

  Future<void> finishPairing() => run('code', () async {
        await pairing!.finish(code.text);
        setState(() => awaitingCode = false);
        code.clear();
      });

  Future<void> connect() => run('verbinden', () async {
        await saveIp();
        if (creds == null) throw StateError('Eerst koppelen');
        await remote?.close();
        final r = AtvRemote(ip.text.trim(), creds!, (m) => log('Chromecast: $m'));
        await r.connect();
        r.appChanges.listen((a) {
          log('Chromecast actieve app: $a');
          if (mounted) setState(() => app = a);
        });
        remote = r;
        log('Chromecast verbonden');
        setState(() {});
      });

  void key(int k, String name) {
    try {
      remote!.key(k);
      log('Chromecast toets $name');
    } catch (e) {
      log('Chromecast toets $name: FOUT $e');
    }
  }

  void launch(String target) {
    try {
      remote!.launch(target);
      log('Chromecast start $target');
    } catch (e) {
      log('Chromecast start: FOUT $e');
    }
  }

  Widget btn(String label, VoidCallback? onTap) =>
      FilledButton.tonal(onPressed: onTap, child: Text(label));

  @override
  Widget build(BuildContext context) {
    final on = remote?.connected ?? false;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
            child: TextField(
                controller: ip,
                decoration: const InputDecoration(labelText: 'IP-adres van de Chromecast'))),
        const SizedBox(width: 12),
        btn(creds == null ? 'Koppel' : 'Opnieuw koppelen', busy ? null : startPairing),
        const SizedBox(width: 8),
        btn('Verbind', busy ? null : connect),
      ]),
      if (awaitingCode)
        Row(children: [
          Expanded(
              child: TextField(
                  controller: code,
                  decoration: const InputDecoration(labelText: 'Code van de tv (6 tekens)'))),
          const SizedBox(width: 12),
          btn('Bevestig', busy ? null : finishPairing),
        ]),
      const SizedBox(height: 8),
      Text(on ? 'Verbonden. Actieve app: $app' : 'Niet verbonden'),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        btn('Omhoog', on ? () => key(AtvKey.up, 'omhoog') : null),
        btn('Omlaag', on ? () => key(AtvKey.down, 'omlaag') : null),
        btn('Links', on ? () => key(AtvKey.left, 'links') : null),
        btn('Rechts', on ? () => key(AtvKey.right, 'rechts') : null),
        btn('OK', on ? () => key(AtvKey.center, 'ok') : null),
        btn('Terug', on ? () => key(AtvKey.back, 'terug') : null),
        btn('Home', on ? () => key(AtvKey.home, 'home') : null),
        btn('Play/pauze', on ? () => key(AtvKey.playPause, 'play/pauze') : null),
        btn('Aan/uit', on ? () => key(AtvKey.power, 'aan/uit') : null),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
            child: TextField(
                controller: pkg,
                decoration: const InputDecoration(labelText: 'Pakketnaam of link van een app'))),
        const SizedBox(width: 12),
        btn('Start', on ? () => launch(pkg.text.trim()) : null),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        btn('YouTube', on ? () => launch('com.google.android.youtube.tv') : null),
        btn('Prime Video', on ? () => launch('com.amazon.amazonvideo.livingroom') : null),
        btn('Netflix', on ? () => launch('com.netflix.ninja') : null),
      ]),
    ]);
  }
}
