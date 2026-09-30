import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ====== CONFIG ======
const String kHost = '74.91.124.21';
const int kPort = 27015;
const Color kGreen = Color(0xFF00FF9C);
const Color kYellow = Color(0xFFFFD400);
const Color kBg = Color(0xFF05090A);
const Color kPanel = Color(0xFF0B1512);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ZeHub());
}

class ZeHub extends StatelessWidget {
  const ZeHub({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: kBg,
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'monospace'),
        ),
        home: const Hub(),
      );
}

// ====== SERVER QUERY (Source A2S_INFO over UDP) ======
class ServerInfo {
  final String name, map;
  final int players, maxPlayers, pingMs;
  ServerInfo(this.name, this.map, this.players, this.maxPlayers, this.pingMs);
}

Future<ServerInfo?> queryServer() async {
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final addr = InternetAddress(kHost);
    final base = <int>[0xFF, 0xFF, 0xFF, 0xFF, 0x54, ...utf8.encode('Source Engine Query'), 0];
    final sw = Stopwatch()..start();
    sock.send(base, addr, kPort);
    final completer = Completer<ServerInfo?>();
    late StreamSubscription sub;
    sub = sock.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = sock!.receive();
      if (d == null) return;
      final b = d.data;
      if (b.length < 6) return;
      if (b[4] == 0x41 && b.length >= 9) {
        // challenge: resend with challenge bytes
        sock.send([...base, ...b.sublist(5, 9)], addr, kPort);
        return;
      }
      if (b[4] == 0x49) {
        sw.stop();
        int i = 6;
        String readStr() {
          final s = i;
          while (i < b.length && b[i] != 0) {
            i++;
          }
          final str = utf8.decode(b.sublist(s, i), allowMalformed: true);
          i++;
          return str;
        }

        final name = readStr();
        final map = readStr();
        readStr(); // folder
        readStr(); // game
        i += 2; // app id
        final players = b[i];
        final max = b[i + 1];
        if (!completer.isCompleted) {
          completer.complete(ServerInfo(name, map, players, max, sw.elapsedMilliseconds));
        }
        sub.cancel();
      }
    });
    return await completer.future.timeout(const Duration(seconds: 4), onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    sock?.close();
  }
}

// ====== DATA ======
class MapTip {
  final String name, diff, tip;
  const MapTip(this.name, this.diff, this.tip);
}

const List<MapTip> kMaps = [
  MapTip('ze_imperium', 'MED', 'Stick with the group, hold choke points.'),
  MapTip('ze_berserk', 'HARD', 'Watch the boss phases, keep moving.'),
  MapTip('ze_dreamin', 'MED', 'Learn the route, rush the escape.'),
  MapTip('ze_minas_tirith', 'HARD', 'Hold the gate, knock back zombies.'),
  MapTip('ze_sandstorm', 'EASY', 'Good warmup map, simple route.'),
  MapTip('ze_ffvii_mako', 'MED', 'Coordinate the elevator holds.'),
];

class LogEntry {
  final String map, result, date;
  LogEntry(this.map, this.result, this.date);
  Map<String, String> toJson() => {'m': map, 'r': result, 'd': date};
  static LogEntry fromJson(Map<String, dynamic> j) => LogEntry(j['m'], j['r'], j['d']);
}

// ====== HUB ======
class Hub extends StatefulWidget {
  const Hub({super.key});
  @override
  State<Hub> createState() => _HubState();
}

class _HubState extends State<Hub> with SingleTickerProviderStateMixin {
  late TabController tabs;
  Timer? poll;
  ServerInfo? info;
  bool offline = false;
  String lastMap = '';
  final List<String> activity = [];

  // alerts
  int alertCount = 20;
  String favMap = 'ze_imperium';
  bool alertsOn = true;
  String banner = '';
  bool countAlerted = false;

  // log
  List<LogEntry> log = [];
  final mapCtl = TextEditingController();

  // scheduler
  DateTime? gameNight;

  SharedPreferences? prefs;

  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 5, vsync: this);
    _load();
    _refresh();
    poll = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }

  @override
  void dispose() {
    poll?.cancel();
    tabs.dispose();
    mapCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    prefs = await SharedPreferences.getInstance();
    setState(() {
      alertCount = prefs!.getInt('alertCount') ?? 20;
      favMap = prefs!.getString('favMap') ?? 'ze_imperium';
      alertsOn = prefs!.getBool('alertsOn') ?? true;
      final raw = prefs!.getString('log');
      if (raw != null) {
        log = (jsonDecode(raw) as List).map((e) => LogEntry.fromJson(e)).toList();
      }
      final gn = prefs!.getString('gameNight');
      if (gn != null) gameNight = DateTime.tryParse(gn);
    });
  }

  void _saveLog() => prefs?.setString('log', jsonEncode(log.map((e) => e.toJson()).toList()));

  String _ts() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(n.hour)}:${p(n.minute)}:${p(n.second)}';
  }

  Future<void> _refresh() async {
    final r = await queryServer();
    if (!mounted) return;
    setState(() {
      if (r == null) {
        offline = true;
        _addActivity('[${_ts()}] no response from server');
      } else {
        offline = false;
        info = r;
        if (r.map != lastMap) {
          _addActivity('[${_ts()}] map: ${r.map}');
          if (alertsOn && r.map == favMap) _fire('FAV MAP LIVE: ${r.map}');
          lastMap = r.map;
        }
        if (alertsOn && r.players >= alertCount) {
          if (!countAlerted) {
            _fire('${r.players} PLAYERS ONLINE');
            countAlerted = true;
          }
        } else {
          countAlerted = false;
        }
      }
    });
  }

  void _addActivity(String s) {
    activity.insert(0, s);
    if (activity.length > 6) activity.removeLast();
  }

  void _fire(String msg) {
    banner = msg;
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) setState(() => banner = '');
    });
  }

  // ====== UI ======
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            if (banner.isNotEmpty)
              Container(
                width: double.infinity,
                color: kYellow,
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('!! $banner !!',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            Expanded(
              child: TabBarView(
                controller: tabs,
                physics: const NeverScrollableScrollPhysics(),
                children: [_statusTab(), _alertsTab(), _mapsTab(), _logTab(), _schedTab()],
              ),
            ),
            Container(
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: kGreen, width: 0.5))),
              child: TabBar(
                controller: tabs,
                indicatorColor: kGreen,
                labelColor: kGreen,
                unselectedLabelColor: Colors.white38,
                labelPadding: EdgeInsets.zero,
                tabs: const [
                  Tab(icon: Icon(Icons.radar, size: 20), text: 'STATUS'),
                  Tab(icon: Icon(Icons.notifications_active, size: 20), text: 'ALERTS'),
                  Tab(icon: Icon(Icons.map, size: 20), text: 'MAPS'),
                  Tab(icon: Icon(Icons.receipt_long, size: 20), text: 'LOG'),
                  Tab(icon: Icon(Icons.event, size: 20), text: 'NIGHT'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() => Container(
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kGreen, width: 0.5))),
        child: Row(
          children: [
            const Icon(Icons.terminal, color: kGreen, size: 20),
            const SizedBox(width: 8),
            const Text('ZE://HUB', style: TextStyle(color: kGreen, fontSize: 18, fontWeight: FontWeight.bold)),
            const Spacer(),
            Icon(Icons.circle, size: 10, color: offline ? Colors.redAccent : kGreen),
            const SizedBox(width: 6),
            Text(offline ? 'OFFLINE' : 'ONLINE',
                style: TextStyle(color: offline ? Colors.redAccent : kGreen, fontSize: 12)),
          ],
        ),
      );

  Widget _panel({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kPanel,
          border: Border.all(color: kGreen.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      );

  Widget _stat(String label, String value, {Color color = kGreen}) => Expanded(
        child: _panel(
          child: Column(
            children: [
              Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(height: 4),
              FittedBox(
                child: Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      );

  // --- STATUS ---
  Widget _statusTab() {
    final i = info;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _panel(
            child: Text(i?.name ?? 'querying $kHost:$kPort ...',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kGreen, fontSize: 13)),
          ),
          const SizedBox(height: 8),
          Row(children: [
            _stat('PLAYERS', i == null ? '--' : '${i.players}/${i.maxPlayers}'),
            const SizedBox(width: 8),
            _stat('PING', i == null ? '--' : '${i.pingMs}ms'),
          ]),
          const SizedBox(height: 8),
          _panel(
            child: Row(children: [
              const Text('MAP> ', style: TextStyle(color: Colors.white54)),
              Expanded(
                child: Text(i?.map ?? '--',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kYellow, fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ACTIVITY LOG', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 6),
                  for (final a in activity) _logLine(a),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _refresh,
              style: OutlinedButton.styleFrom(side: const BorderSide(color: kGreen), foregroundColor: kGreen),
              child: const Text('REFRESH'),
            ),
          ),
        ],
      ),
    );
  }

  // colors only the map name yellow
  Widget _logLine(String line) {
    final idx = line.indexOf('map: ');
    if (idx == -1) {
      return Text(line, style: const TextStyle(color: kGreen, fontSize: 12));
    }
    return Text.rich(TextSpan(children: [
      TextSpan(text: line.substring(0, idx + 5), style: const TextStyle(color: kGreen, fontSize: 12)),
      TextSpan(text: line.substring(idx + 5), style: const TextStyle(color: kYellow, fontSize: 12)),
    ]));
  }

  // --- ALERTS ---
  Widget _alertsTab() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _panel(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeColor: kGreen,
              title: const Text('ALERTS ENABLED', style: TextStyle(color: kGreen)),
              value: alertsOn,
              onChanged: (v) {
                setState(() => alertsOn = v);
                prefs?.setBool('alertsOn', v);
              },
            ),
          ),
          const SizedBox(height: 8),
          _panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PLAYER COUNT TRIGGER: $alertCount+', style: const TextStyle(color: kGreen)),
                Slider(
                  value: alertCount.toDouble(),
                  min: 1,
                  max: 64,
                  divisions: 63,
                  activeColor: kGreen,
                  onChanged: (v) => setState(() => alertCount = v.round()),
                  onChangeEnd: (v) => prefs?.setInt('alertCount', v.round()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('FAVORITE MAP TRIGGER', style: TextStyle(color: kGreen)),
                DropdownButton<String>(
                  isExpanded: true,
                  dropdownColor: kPanel,
                  value: kMaps.any((m) => m.name == favMap) ? favMap : kMaps.first.name,
                  items: [
                    for (final m in kMaps)
                      DropdownMenuItem(value: m.name, child: Text(m.name, style: const TextStyle(color: kYellow))),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => favMap = v);
                    prefs?.setString('favMap', v);
                  },
                ),
              ],
            ),
          ),
          const Spacer(),
          const Text('Alerts fire while the app is open (banner + vibration).',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
    );
  }

  // --- MAPS ---
  Widget _mapsTab() {
    Color dc(String d) => d == 'EASY' ? kGreen : (d == 'MED' ? kYellow : Colors.redAccent);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          for (final m in kMaps)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _panel(
                  child: Row(children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(m.name, style: const TextStyle(color: kYellow, fontWeight: FontWeight.bold)),
                          Text(m.tip, style: const TextStyle(color: Colors.white60, fontSize: 11), maxLines: 2),
                        ],
                      ),
                    ),
                    Text(m.diff, style: TextStyle(color: dc(m.diff), fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // --- LOG ---
  Widget _logTab() {
    final wins = log.where((e) => e.result == 'ESCAPED').length;
    final losses = log.length - wins;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(children: [
            _stat('ESCAPES', '$wins'),
            const SizedBox(width: 8),
            _stat('DEATHS', '$losses', color: Colors.redAccent),
            const SizedBox(width: 8),
            _stat('SESSIONS', '${log.length}', color: kYellow),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: mapCtl,
            style: const TextStyle(color: kYellow),
            decoration: InputDecoration(
              hintText: info?.map ?? 'map name',
              hintStyle: const TextStyle(color: Colors.white30),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: kGreen.withOpacity(0.5))),
              focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: kGreen)),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _logBtn('ESCAPED', kGreen)),
            const SizedBox(width: 8),
            Expanded(child: _logBtn('DIED', Colors.redAccent)),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: _panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('RECENT', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 6),
                  for (final e in log.reversed.take(6))
                    Text.rich(TextSpan(children: [
                      TextSpan(text: '${e.date}  ', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                      TextSpan(text: e.map, style: const TextStyle(color: kYellow, fontSize: 12)),
                      TextSpan(
                        text: '  ${e.result}',
                        style: TextStyle(color: e.result == 'ESCAPED' ? kGreen : Colors.redAccent, fontSize: 12),
                      ),
                    ])),
                ],
              ),
            ),
          ),
          if (log.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() => log.removeLast());
                _saveLog();
              },
              child: const Text('UNDO LAST', style: TextStyle(color: Colors.white38)),
            ),
        ],
      ),
    );
  }

  Widget _logBtn(String result, Color c) => OutlinedButton(
        onPressed: () {
          final m = mapCtl.text.trim().isNotEmpty ? mapCtl.text.trim() : (info?.map ?? 'unknown');
          final n = DateTime.now();
          setState(() => log.add(LogEntry(m, result, '${n.month}/${n.day}')));
          _saveLog();
          mapCtl.clear();
          FocusScope.of(context).unfocus();
        },
        style: OutlinedButton.styleFrom(side: BorderSide(color: c), foregroundColor: c),
        child: Text(result),
      );

  // --- SCHEDULER ---
  Widget _schedTab() {
    String countdown = 'NOT SET';
    if (gameNight != null) {
      final d = gameNight!.difference(DateTime.now());
      if (d.isNegative) {
        countdown = 'IT\'S GAME TIME';
      } else {
        countdown = '${d.inDays}d ${d.inHours % 24}h ${d.inMinutes % 60}m';
      }
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _panel(
            child: Column(children: [
              const Text('NEXT GAME NIGHT', style: TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(height: 10),
              FittedBox(
                child: Text(countdown, style: const TextStyle(color: kGreen, fontSize: 32, fontWeight: FontWeight.bold)),
              ),
              if (gameNight != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(gameNight.toString().substring(0, 16), style: const TextStyle(color: kYellow)),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _pickDate,
              style: OutlinedButton.styleFrom(side: const BorderSide(color: kGreen), foregroundColor: kGreen),
              child: const Text('SET DATE & TIME'),
            ),
          ),
          if (gameNight != null)
            TextButton(
              onPressed: () {
                setState(() => gameNight = null);
                prefs?.remove('gameNight');
              },
              child: const Text('CLEAR', style: TextStyle(color: Colors.white38)),
            ),
          const Spacer(),
          const Text('Countdown updates when you open this tab.',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 20, minute: 0));
    if (t == null) return;
    final dt = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    setState(() => gameNight = dt);
    prefs?.setString('gameNight', dt.toIso8601String());
  }
}
