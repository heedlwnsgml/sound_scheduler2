import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// 'localizations.dart' import 제거됨 (7개 오류 해결)
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sound_mode/sound_mode.dart';
import 'package:sound_mode/utils/ringer_mode_statuses.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- 백그라운드 알람 콜백 ---
const String kScheduleListKey = 'scheduleList';
const String kOriginalRingerModeKey = 'originalRingerMode';
const String kBackgroundPortName = 'background_port';

SharedPreferences? _prefs;

// 1. 예약된 모드로 변경하는 콜백
@pragma('vm:entry-point')
void setScheduledModeCallback(int id, Map<String, dynamic> params) async {
  print("알람 $id: setScheduledModeCallback 실행");
  WidgetsFlutterBinding.ensureInitialized();
  _prefs = await SharedPreferences.getInstance();

  final String modeToSet = params['mode'] as String? ?? 'silent';

  try {
    // 1.1 현재 소리 모드 저장 (복원을 위해)
    RingerModeStatus currentMode = await SoundMode.ringerModeStatus;
    await _prefs!.setString(kOriginalRingerModeKey, currentMode.name);
    print("현재 모드 저장: ${currentMode.name}");

    // 1.2 예약된 모드로 설정
    RingerModeStatus targetMode;
    if (modeToSet == 'vibrate') {
      targetMode = RingerModeStatus.vibrate;
    } else if (modeToSet == 'sound') {
      targetMode = RingerModeStatus.normal;
    } else {
      targetMode = RingerModeStatus.silent;
    }

    await SoundMode.setSoundMode(targetMode);
    print("알람 $id: 모드 변경 완료 -> $modeToSet");
  } catch (e) {
    print("알람 $id: 모드 변경 실패: $e");
  }

  // 1.3 UI 업데이트를 위한 포트 전송
  final SendPort? sendPort =
  IsolateNameServer.lookupPortByName(kBackgroundPortName);
  sendPort?.send({'id': id, 'status': 'started'});
}

// 2. 원래 모드로 복원하는 콜백
@pragma('vm:entry-point')
void revertToOriginalModeCallback(int id, Map<String, dynamic> params) async {
  print("알람 $id: revertToOriginalModeCallback 실행");
  WidgetsFlutterBinding.ensureInitialized();
  _prefs = await SharedPreferences.getInstance();

  try {
    // 2.1 SharedPreferences에서 저장해둔 'originalMode' 로드
    String? originalModeName = _prefs!.getString(kOriginalRingerModeKey);
    RingerModeStatus originalMode = RingerModeStatus.values.firstWhere(
          (e) => e.name == originalModeName,
      orElse: () => RingerModeStatus.normal, // 기본값은 '소리'
    );

    // 2.2 원래 모드로 복원
    await SoundMode.setSoundMode(originalMode);
    print("알람 $id: 원래 모드($originalModeName)로 복원됨");

    // 2.3 저장했던 키 삭제
    await _prefs!.remove(kOriginalRingerModeKey);
  } catch (e) {
    print("알람 $id: 모드 복원 실패: $e");
  }

  // 2.4 UI 업데이트를 위한 포트 전송
  final SendPort? sendPort =
  IsolateNameServer.lookupPortByName(kBackgroundPortName);
  sendPort?.send({'id': id, 'status': 'ended'});
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ko_KR', null); // 한국어 날짜 포매팅 (intl)
  await AndroidAlarmManager.initialize();

  runApp(const SoundSchedulerApp());
}

class SoundSchedulerApp extends StatelessWidget {
  const SoundSchedulerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '소리/진동 제어',
      // --- 'localizationsDelegates' 및 'supportedLocales' 제거됨 (7개 오류 해결) ---
      locale: const Locale('ko'), // 'intl' 패키지를 위한 로케일 설정
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Colors.black,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Colors.black),
        ),
      ),
      home: const HomePage(),
    );
  }
}

// --- 홈 페이지 (메인 화면) ---
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Schedule> _schedules = [];
  bool _isLoading = true;
  late SharedPreferences _prefs;

  final ReceivePort _receivePort = ReceivePort();

  @override
  void initState() {
    super.initState();
    _initApp();

    // 백그라운드 아이솔레이트로부터 메시지 수신
    IsolateNameServer.registerPortWithName(
        _receivePort.sendPort, kBackgroundPortName);
    _receivePort.listen((message) {
      print("메인 Isolate가 메시지 받음: $message");
      _loadSchedules(); // 알람이 시작/종료되면 목록 새로고침
    });
  }

  @override
  void dispose() {
    IsolateNameServer.removePortNameMapping(kBackgroundPortName);
    _receivePort.close();
    super.dispose();
  }

  Future<void> _initApp() async {
    _prefs = await SharedPreferences.getInstance();
    await _checkAndRequestPermissions();
    await _loadSchedules();
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _checkAndRequestPermissions() async {
    // 1. 방해 금지 권한 (permission_handler 사용)
    var dndStatus = await Permission.accessNotificationPolicy.status;
    if (dndStatus.isDenied) {
      await _showPermissionDialog(
        title: '방해 금지 접근 권한을 허용하시겠습니까?',
        content:
        '소리/진동/무음 모드 변경시 사용됩니다.\n허용하지 않을 경우, 어플이 정상 작동하지 않을 수 있습니다.',
        onAllow: () async {
          await Permission.accessNotificationPolicy.request();
        },
        onDeny: () => SystemNavigator.pop(),
      );
    }

    // 2. 정확한 알람 권한 (permission_handler 사용)
    var alarmStatus = await Permission.scheduleExactAlarm.status;
    if (alarmStatus.isDenied) {
      await _showPermissionDialog(
          title: '정확한 알림 사용 권한을 허용하시겠습니까?',
          content:
          '이 권한을 허용하면, 앱이 사용자가 지정한 시간에 맞춰 정확하게 모드로 전환할 수 있습니다.',
          onAllow: () async {
            await Permission.scheduleExactAlarm.request();
          },
          onDeny: () {
            print("정확한 알람 권한이 거부되었습니다.");
          });
    }
  }

  Future<void> _showPermissionDialog({
    required String title,
    required String content,
    required VoidCallback onAllow,
    required VoidCallback onDeny,
  }) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onDeny();
            },
            child: const Text('허용 안함'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onAllow();
            },
            child: const Text('허용'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadSchedules() async {
    final List<String> scheduleStrings =
        _prefs.getStringList(kScheduleListKey) ?? [];
    setState(() {
      _schedules =
          scheduleStrings.map((s) => Schedule.fromJson(jsonDecode(s))).toList();
      // 종료된 일정은 비활성화
      final now = DateTime.now();
      for (var s in _schedules) {
        if (s.isActive && now.isAfter(s.endTime)) {
          s.isActive = false;
        }
      }
    });
  }

  Future<void> _saveSchedules() async {
    final List<String> scheduleStrings =
    _schedules.map((s) => jsonEncode(s.toJson())).toList();
    await _prefs.setStringList(kScheduleListKey, scheduleStrings);
  }

  Future<void> _scheduleAlarm(Schedule schedule) async {
    final int startAlarmId = schedule.hashCode.abs() % 2147483647;
    final int endAlarmId = (schedule.hashCode + 1).abs() % 2147483647;
    await _cancelAlarm(schedule, quiet: true);
    if (schedule.isActive) {
      print("알람 등록 시도: ${schedule.message}");
      await AndroidAlarmManager.oneShotAt(
        schedule.startTime,
        startAlarmId,
        setScheduledModeCallback,
        params: {'mode': schedule.mode.name},
        alarmClock: true,
        allowWhileIdle: true,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: true,
      );
      await AndroidAlarmManager.oneShotAt(
        schedule.endTime,
        endAlarmId,
        revertToOriginalModeCallback,
        alarmClock: true,
        allowWhileIdle: true,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: true,
      );
      print(
          "알람 등록 완료: StartID $startAlarmId (${schedule.mode.name}), EndID $endAlarmId");
    }
  }

  Future<void> _cancelAlarm(Schedule schedule, {bool quiet = false}) async {
    final int startAlarmId = schedule.hashCode.abs() % 2147483647;
    final int endAlarmId = (schedule.hashCode + 1).abs() % 2147483647;
    await AndroidAlarmManager.cancel(startAlarmId);
    await AndroidAlarmManager.cancel(endAlarmId);
    if (!quiet) {
      print("알람 취소: $startAlarmId, $endAlarmId");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('소리/진동 제어'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _schedules.isEmpty
          ? _buildEmptyState()
          : _buildScheduleList(),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final newSchedule = await Navigator.push<Schedule>(
            context,
            MaterialPageRoute(builder: (context) => const AddSchedulePage()),
          );
          if (newSchedule != null) {
            setState(() {
              _schedules.add(newSchedule);
            });
            await _saveSchedules();
            await _scheduleAlarm(newSchedule);
          }
        },
        backgroundColor: Colors.blue,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Text(
        '설정된 기간이 없습니다',
        style: TextStyle(fontSize: 18, color: Colors.grey),
      ),
    );
  }

  Widget _buildScheduleList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _schedules.length,
      itemBuilder: (context, index) {
        final schedule = _schedules[index];
        final now = DateTime.now();
        String statusText;
        Color statusColor;

        if (!schedule.isActive) {
          statusText = "비활성화됨";
          statusColor = Colors.grey;
        } else if (now.isAfter(schedule.startTime) &&
            now.isBefore(schedule.endTime)) {
          statusText =
          "활성화 중 (종료: ${DateFormat('HH:mm').format(schedule.endTime)})";
          statusColor = Colors.red;
        } else if (now.isBefore(schedule.startTime)) {
          final diff = schedule.startTime.difference(now);
          statusText = "${diff.inHours}시간 ${diff.inMinutes % 60}분 후 활성화";
          statusColor = Colors.blue;
        } else {
          statusText = "종료됨";
          schedule.isActive = false; // 자동 비활성화
          statusColor = Colors.grey;
        }

        return Card(
          elevation: 2,
          margin: const EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            contentPadding:
            const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            title: Text(
              schedule.message,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Text(
                  // 'intl'을 사용한 한글 날짜 포맷
                  '${DateFormat('MM/dd(E) HH:mm', 'ko_KR').format(schedule.startTime)} - ${DateFormat('HH:mm').format(schedule.endTime)}',
                  style: TextStyle(color: Colors.grey[700]),
                ),
                const SizedBox(height: 4),
                Text(
                  '모드: ${schedule.mode.displayName}', // (Extension에서 한글로 변환됨)
                  style: TextStyle(color: Colors.grey[700]),
                ),
                const SizedBox(height: 4),
                Text(
                  statusText,
                  style: TextStyle(
                      color: statusColor, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            trailing: Switch(
              value: schedule.isActive,
              onChanged: (value) async {
                setState(() {
                  schedule.isActive = value;
                });
                await _saveSchedules();
                if (value) {
                  // 다시 활성화할 때, 시간이 과거면 안 됨
                  if (schedule.endTime.isAfter(DateTime.now())) {
                    await _scheduleAlarm(schedule);
                  } else {
                    setState(() => schedule.isActive = false); // 즉시 다시 끔
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              '종료된 일정은 다시 켤 수 없습니다.')),
                    );
                  }
                } else {
                  await _cancelAlarm(schedule);
                }
              },
            ),
            onLongPress: () async {
              // 길게 눌러 삭제
              final bool? confirmDelete = await showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('일정 삭제'),
                  content: Text(
                      "'${schedule.message}' 일정을 삭제하시겠습니까?"),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('취소'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('삭제',
                          style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              );

              if (confirmDelete == true) {
                await _cancelAlarm(schedule);
                setState(() {
                  _schedules.removeAt(index);
                });
                await _saveSchedules();
              }
            },
          ),
        );
      },
    );
  }
}

// --- 일정 추가 페이지 (PDF 페이지 4) ---
// <<< 여기가 TextField (수동 입력)을 사용하는 "우회" 코드로 수정된 부분입니다 (한글) >>>
class AddSchedulePage extends StatefulWidget {
  const AddSchedulePage({super.key});

  @override
  State<AddSchedulePage> createState() => _AddSchedulePageState();
}

// PDF 4의 아이콘(소리, 진동, 무음)에 맞게 Enum 정의
enum SoundModeEnum { sound, vibrate, silent }

extension SoundModeExtension on SoundModeEnum {
  String get displayName {
    switch (this) {
      case SoundModeEnum.sound:
        return '소리';
      case SoundModeEnum.vibrate:
        return '진동';
      case SoundModeEnum.silent:
        return '무음';
    }
  }
}

class _AddSchedulePageState extends State<AddSchedulePage> {
  // --- DatePicker/TimePicker 대신 TextField 컨트롤러 사용 ---
  late TextEditingController _startHourController;
  late TextEditingController _startMinuteController;
  late TextEditingController _endHourController;
  late TextEditingController _endMinuteController;
  DateTime _startDate = DateTime.now();
  // ---

  SoundModeEnum _selectedMode = SoundModeEnum.silent; // PDF 4 기본값 '무음'
  final TextEditingController _messageController =
  TextEditingController(text: "회의");
  Set<int> _selectedDays = {DateTime.now().weekday};

  @override
  void initState() {
    super.initState();
    final now = DateTime.now().add(const Duration(minutes: 5));
    final end = now.add(const Duration(hours: 1));
    _startHourController = TextEditingController(text: now.hour.toString());
    _startMinuteController = TextEditingController(text: now.minute.toString());
    _endHourController = TextEditingController(text: end.hour.toString());
    _endMinuteController = TextEditingController(text: end.minute.toString());
  }

  @override
  void dispose() {
    _startHourController.dispose();
    _startMinuteController.dispose();
    _endHourController.dispose();
    _endMinuteController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  // --- _selectDate 함수만 남김 ---
  // (TextField로 대체되었으므로 _selectTime 함수는 제거됨)
  Future<void> _selectDate(BuildContext context) async {
    // DatePicker는 localizations가 필요 없으므로 그대로 사용합니다.
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && picked != _startDate) {
      setState(() {
        _startDate = picked;
        _selectedDays = {picked.weekday};
      });
    }
  }
  // ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('새 일정 추가'),
        actions: [
          TextButton(
            onPressed: _saveSchedule,
            child: const Text(
              '저장',
              style: TextStyle(
                color: Colors.blue,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _messageController,
              decoration: InputDecoration(
                labelText: '메시지 (예: 회의, 수면)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 24),
            // <<<--- TextField UI로 수정 ---
            _buildDateTimeSelection(),
            // ---
            const SizedBox(height: 24),
            _buildDaySelector(),
            const SizedBox(height: 24),
            _buildModeSelector(),
          ],
        ),
      ),
    );
  }

  // <<<--- _buildDateTimeSelection 위젯 (TextField 사용) ---
  Widget _buildDateTimeSelection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 날짜 선택 (DatePicker는 localizations 필요 없음)
        const Text('시작 날짜', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        TextButton(
          onPressed: () => _selectDate(context),
          child: Text(
            DateFormat('M월 d일 (E)', 'ko_KR').format(_startDate), // 한글 포맷
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 시작 시간 입력
        const Text('시작 시간', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _startHourController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: '시 (0-23)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _startMinuteController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: '분 (0-59)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // 종료 시간 입력
        const Text('종료 시간', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _endHourController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: '시 (0-23)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _endMinuteController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: '분 (0-59)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
  // ---

  Widget _buildDaySelector() {
    final List<String> weekDays = ['월', '화', '수', '목', '금', '토', '일'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('반복 요일',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(7, (index) {
            final day = index + 1; // DateTime.monday = 1
            final isSelected = _selectedDays.contains(day);
            return GestureDetector(
              onTap: () {
                setState(() {
                  if (_selectedDays.contains(day)) {
                    _selectedDays.remove(day);
                  } else {
                    _selectedDays.add(day);
                  }
                });
              },
              child: CircleAvatar(
                radius: 20,
                backgroundColor: isSelected ? Colors.blue : Colors.grey[200],
                child: Text(
                  weekDays[index],
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.black,
                    fontWeight:
                    isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildModeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('모드 선택',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildModeOption(context,
                icon: Icons.volume_up,
                label: '소리',
                mode: SoundModeEnum.sound),
            _buildModeOption(context,
                icon: Icons.vibration,
                label: '진동',
                mode: SoundModeEnum.vibrate),
            _buildModeOption(context,
                icon: Icons.volume_off,
                label: '무음',
                mode: SoundModeEnum.silent),
          ],
        ),
      ],
    );
  }

  Widget _buildModeOption(
      BuildContext context, {
        required IconData icon,
        required String label,
        required SoundModeEnum mode,
      }) {
    final bool isSelected = _selectedMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _selectedMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color:
          isSelected ? Colors.blue.withAlpha(26) : Colors.transparent, // withOpacity 경고 수정
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.blue : Colors.grey[300]!,
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: isSelected ? Colors.blue : Colors.grey[600], size: 30),
            const SizedBox(height: 8),
            Text(label,
                style: TextStyle(
                    color: isSelected ? Colors.blue : Colors.grey[600],
                    fontWeight:
                    isSelected ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }

  // <<<--- _saveSchedule 함수 (TextField 컨트롤러 값 읽기) ---
  void _saveSchedule() {
    // 1. TextField에서 시/분 읽기
    final int startHour = int.tryParse(_startHourController.text) ?? 0;
    final int startMinute = int.tryParse(_startMinuteController.text) ?? 0;
    final int endHour = int.tryParse(_endHourController.text) ?? 0;
    final int endMinute = int.tryParse(_endMinuteController.text) ?? 0;

    // 2. 유효성 검사 (0-23시, 0-59분)
    if (startHour > 23 || startMinute > 59 || endHour > 23 || endMinute > 59) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('시간(0-23)과 분(0-59)을 올바르게 입력하세요.')),
      );
      return;
    }

    // 3. Date/Time 변수로 변환
    DateTime startDateTime = DateTime(
      _startDate.year,
      _startDate.month,
      _startDate.day,
      startHour,
      startMinute,
    );
    DateTime endDateTime = DateTime(
      _startDate.year,
      _startDate.month,
      _startDate.day,
      endHour,
      endMinute,
    );

    // 4. 만약 종료 시간이 시작 시간보다 빠르거나 같다면, 종료 시간을 "다음 날"로 설정
    if (endDateTime.isBefore(startDateTime) || endDateTime.isAtSameMomentAs(startDateTime)) {
      endDateTime = endDateTime.add(const Duration(days: 1));
    }

    // 5. 만약 설정한 시작 시간이 이미 지났다면 (내일 날짜를 선택하지 않은 경우)
    if (startDateTime.isBefore(DateTime.now())) {
      // (테스트를 위해 1분 정도의 여유를 줌)
      if (startDateTime.isBefore(DateTime.now().subtract(const Duration(minutes: 1)))) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  '시작 시간은 현재 시간 이후여야 합니다.')),
        );
        return;
      }
    }

    final newSchedule = Schedule(
      startTime: startDateTime,
      endTime: endDateTime,
      mode: _selectedMode,
      message: _messageController.text.isEmpty
          ? '이름 없음'
          : _messageController.text,
      days: _selectedDays.toList(),
      isActive: true,
    );

    print('일정 저장됨: ${newSchedule.message} (모드: ${newSchedule.mode.name})');
    Navigator.of(context).pop(newSchedule);
  }
}
// ---

// --- 데이터 모델 ---
class Schedule {
  final DateTime startTime;
  final DateTime endTime;
  final SoundModeEnum mode; // Enum 타입 사용
  final String message;
  final List<int> days; // 1 = 월요일, 7 = 일요일
  bool isActive;

  Schedule({
    required this.startTime,
    required this.endTime,
    required this.mode,
    required this.message,
    required this.days,
    this.isActive = true,
  });

  // toJson: Schedule 객체를 JSON(Map)으로 변환 (저장용)
  Map<String, dynamic> toJson() => {
    'startTime': startTime.toIso8601String(),
    'endTime': endTime.toIso8601String(),
    'mode': mode.name, // Enum을 String으로 저장
    'message': message,
    'days': days,
    'isActive': isActive,
  };

  // fromJson: JSON(Map)을 Schedule 객체로 변환 (불러오기용)
  factory Schedule.fromJson(Map<String, dynamic> json) => Schedule(
    startTime: DateTime.parse(json['startTime']),
    endTime: DateTime.parse(json['endTime']),
    mode: SoundModeEnum.values.firstWhere(
            (e) => e.name == json['mode'],
        orElse: () => SoundModeEnum.silent // 혹시 모를 오류 대비 기본값
    ),
    message: json['message'],
    days: List<int>.from(json['days']),
    isActive: json['isActive'],
  );
}