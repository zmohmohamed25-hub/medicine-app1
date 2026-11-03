import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

final FlutterLocalNotificationsPlugin np = FlutterLocalNotificationsPlugin();
final ValueNotifier<String?> alarmMedId = ValueNotifier(null);
final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  await np.initialize(
    const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    onDidReceiveNotificationResponse: (r) {
      if (r.payload != null) alarmMedId.value = r.payload;
    },
  );
  final d = await np.getNotificationAppLaunchDetails();
  if (d?.didNotificationLaunchApp ?? false) {
    alarmMedId.value = d!.notificationResponse?.payload;
  }
  final a = np.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await a?.requestNotificationsPermission();
  try {
    await a?.requestExactAlarmsPermission();
  } catch (_) {}
  runApp(const MedApp());
}

class MedApp extends StatelessWidget {
  const MedApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: navKey,
        title: 'أدويتي',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        builder: (c, w) =>
            Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const HomePage(),
      );
}

class Med {
  String id, name, dose;
  int everyHours;
  int? days;
  DateTime start;
  int hour, minute;
  List<String> taken;
  Med(this.id, this.name, this.dose, this.everyHours, this.days, this.start,
      this.hour, this.minute,
      [List<String>? t])
      : taken = t ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'dose': dose,
        'every': everyHours,
        'days': days,
        'start': start.toIso8601String(),
        'hour': hour,
        'minute': minute,
        'taken': taken,
      };

  factory Med.fromJson(Map<String, dynamic> j) {
    final st = DateTime.parse(j['start']);
    return Med(
      (j['id'] ?? st.millisecondsSinceEpoch.toString()).toString(),
      j['name'],
      j['dose'],
      j['every'],
      j['days'],
      st,
      j['hour'] ?? st.hour,
      j['minute'] ?? st.minute,
      List<String>.from(j['taken'] ?? []),
    );
  }

  int get dayNo {
    final n = DateTime.now();
    return DateTime.utc(n.year, n.month, n.day)
            .difference(DateTime.utc(start.year, start.month, start.day))
            .inDays +
        1;
  }

  bool get finished => days != null && dayNo > days!;

  int get takenToday {
    final n = DateTime.now();
    return taken.where((s) {
      final d = DateTime.parse(s);
      return d.year == n.year && d.month == n.month && d.day == n.day;
    }).length;
  }

  /// مواعيد الجرعات القادمة (لحد 7 أيام أو لحد نهاية الكورس)
  List<DateTime> upcoming() {
    final base = DateTime(start.year, start.month, start.day, hour, minute);
    final now = DateTime.now();
    final end = days == null
        ? now.add(const Duration(days: 7))
        : base.add(Duration(days: days!));
    final limit = days == null ? now.add(const Duration(days: 7)) : end;
    final out = <DateTime>[];
    var t = base;
    while (t.isBefore(limit) && out.length < 60) {
      if (t.isAfter(now)) out.add(t);
      t = t.add(Duration(hours: everyHours));
    }
    return out;
  }
}

Future<String?> getRingtone() async {
  final p = await SharedPreferences.getInstance();
  final path = p.getString('ringtone');
  if (path != null && File(path).existsSync()) return path;
  return null;
}

Future<void> scheduleAll(List<Med> meds) async {
  await np.cancelAll();
  final custom = await getRingtone() != null;
  final channelId = custom ? 'med_alarm_silent' : 'med_alarm_sound';
  final details = NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      custom ? 'تنبيه الدواء (رنين من التطبيق)' : 'تنبيه الدواء',
      channelDescription: 'تنبيهات مواعيد الأدوية',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      playSound: !custom,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      enableVibration: true,
      ongoing: true,
      autoCancel: true,
      visibility: NotificationVisibility.public,
    ),
  );
  int n = 0;
  for (final m in meds) {
    if (m.finished) continue;
    for (final t in m.upcoming()) {
      n++;
      final when = tz.TZDateTime.from(t, tz.UTC);
      Future<void> go(AndroidScheduleMode mode) => np.zonedSchedule(
            n,
            'حان موعد الدواء 💊',
            '${m.name}${m.dose.isEmpty ? '' : ' - ${m.dose}'}',
            when,
            details,
            androidScheduleMode: mode,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            payload: m.id,
          );
      try {
        await go(AndroidScheduleMode.exactAllowWhileIdle);
      } catch (_) {
        try {
          await go(AndroidScheduleMode.inexactAllowWhileIdle);
        } catch (_) {}
      }
    }
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<Med> meds = [];
  String? ringName;
  bool alarmOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    alarmMedId.addListener(openAlarm);
    load().then((_) => openAlarm());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    alarmMedId.removeListener(openAlarm);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) async {
    if (s == AppLifecycleState.resumed) {
      final a = np.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final act = await a?.getActiveNotifications() ?? [];
      for (final x in act) {
        if (x.payload != null) {
          alarmMedId.value = x.payload;
          break;
        }
      }
    }
  }

  void openAlarm() {
    final id = alarmMedId.value;
    if (id == null || alarmOpen || meds.isEmpty) return;
    final idx = meds.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    alarmOpen = true;
    final m = meds[idx];
    navKey.currentState
        ?.push(MaterialPageRoute(
            fullscreenDialog: true, builder: (_) => AlarmPage(med: m)))
        .then((taken) {
      alarmOpen = false;
      alarmMedId.value = null;
      if (taken == true) {
        setState(() => m.taken.add(DateTime.now().toIso8601String()));
        save();
      }
    });
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString('meds');
    final r = p.getString('ringtone_name');
    setState(() {
      ringName = r;
      if (s != null) {
        meds = (jsonDecode(s) as List)
            .map((e) => Med.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    });
    await scheduleAll(meds);
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'meds', jsonEncode(meds.map((m) => m.toJson()).toList()));
    await scheduleAll(meds);
  }

  Future<void> pickRingtone() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (res == null || res.files.single.path == null) return;
    final src = File(res.files.single.path!);
    final dir = await getApplicationDocumentsDirectory();
    final dst = await src.copy('${dir.path}/ringtone_${res.files.single.name}');
    final p = await SharedPreferences.getInstance();
    await p.setString('ringtone', dst.path);
    await p.setString('ringtone_name', res.files.single.name);
    setState(() => ringName = res.files.single.name);
    await scheduleAll(meds);
  }

  Future<void> resetRingtone() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('ringtone');
    await p.remove('ringtone_name');
    setState(() => ringName = null);
    await scheduleAll(meds);
  }

  void addMed() {
    final name = TextEditingController();
    final dose = TextEditingController();
    final days = TextEditingController();
    int every = 8;
    TimeOfDay first = TimeOfDay.now();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('دواء جديد'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'اسم الدواء')),
              TextField(
                  controller: dose,
                  decoration:
                      const InputDecoration(labelText: 'الجرعة (مثلاً حباية)')),
              DropdownButtonFormField<int>(
                value: every,
                decoration: const InputDecoration(labelText: 'كل كام ساعة'),
                items: [4, 6, 8, 12, 24]
                    .map((h) =>
                        DropdownMenuItem(value: h, child: Text('كل $h ساعة')))
                    .toList(),
                onChanged: (v) => setS(() => every = v!),
              ),
              TextField(
                  controller: days,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'عدد الأيام (فاضي = مستمر)')),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.access_time),
                label: Text('ميعاد أول جرعة: ${first.format(ctx)}'),
                onPressed: () async {
                  final t = await showTimePicker(
                      context: ctx, initialTime: first);
                  if (t != null) setS(() => first = t);
                },
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                final now = DateTime.now();
                setState(() => meds.add(Med(
                    now.millisecondsSinceEpoch.toString(),
                    name.text.trim(),
                    dose.text.trim(),
                    every,
                    int.tryParse(days.text),
                    now,
                    first.hour,
                    first.minute)));
                save();
                Navigator.pop(ctx);
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('أدويتي'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.music_note),
            tooltip: 'الرنين',
            onSelected: (v) => v == 'pick' ? pickRingtone() : resetRingtone(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pick', child: Text('اختيار رنين من الجهاز')),
              PopupMenuItem(value: 'reset', child: Text('استخدام رنين النظام')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: addMed,
          icon: const Icon(Icons.add),
          label: const Text('دواء')),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.all(10),
          child: Text('🔔 الرنين: ${ringName ?? 'رنين النظام'}'),
        ),
        Expanded(
          child: meds.isEmpty
              ? const Center(child: Text('مفيش أدوية لسه. دوس + عشان تضيف'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: meds.length,
                  itemBuilder: (c, i) {
                    final m = meds[i];
                    final per = 24 ~/ m.everyHours;
                    final status = m.finished
                        ? 'خلص العلاج ✅'
                        : m.days == null
                            ? 'علاج مستمر'
                            : 'اليوم ${m.dayNo} من ${m.days}';
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Expanded(
                                    child: Text(m.name,
                                        style: const TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold))),
                                IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () {
                                      setState(() => meds.removeAt(i));
                                      save();
                                    }),
                              ]),
                              Text(
                                  '${m.dose} • كل ${m.everyHours} ساعة • أول جرعة ${m.hour.toString().padLeft(2, '0')}:${m.minute.toString().padLeft(2, '0')}'),
                              const SizedBox(height: 6),
                              Text(status),
                              if (!m.finished) ...[
                                Text(
                                    'الجرعات النهاردة: ${m.takenToday} من $per'),
                                const SizedBox(height: 8),
                                FilledButton(
                                  onPressed: () {
                                    setState(() => m.taken
                                        .add(DateTime.now().toIso8601String()));
                                    save();
                                  },
                                  child: const Text('أخدت الجرعة'),
                                ),
                              ],
                            ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

class AlarmPage extends StatefulWidget {
  final Med med;
  const AlarmPage({super.key, required this.med});
  @override
  State<AlarmPage> createState() => _AlarmPageState();
}

class _AlarmPageState extends State<AlarmPage> {
  final player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    start();
  }

  Future<void> start() async {
    final path = await getRingtone();
    if (path != null) {
      await player.setReleaseMode(ReleaseMode.loop);
      await player.play(DeviceFileSource(path));
    }
  }

  Future<void> stop(bool taken) async {
    await player.stop();
    await np.cancelAll().then((_) async {});
    if (mounted) Navigator.pop(context, taken);
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.med;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.teal.shade900,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.alarm, size: 90, color: Colors.white),
                const SizedBox(height: 20),
                const Text('حان موعد الدواء',
                    style: TextStyle(fontSize: 22, color: Colors.white70)),
                const SizedBox(height: 12),
                Text(m.name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                if (m.dose.isNotEmpty)
                  Text(m.dose,
                      style:
                          const TextStyle(fontSize: 24, color: Colors.white)),
                const SizedBox(height: 50),
                SizedBox(
                  width: double.infinity,
                  height: 60,
                  child: FilledButton(
                    onPressed: () => stop(true),
                    child:
                        const Text('أخدت الجرعة', style: TextStyle(fontSize: 20)),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white),
                    onPressed: () => stop(false),
                    child: const Text('إيقاف الرنين',
                        style: TextStyle(fontSize: 18)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
