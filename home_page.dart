import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sound_mode/sound_mode.dart';
import 'package:sound_mode/utils/ringer_mode_statuses.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';

import '../models/schedule_model.dart';
import '../services/background_service.dart';
import 'add_schedule_page.dart';

const String kScheduleListKey = 'scheduleList';
const String kOriginalRingerModeKey = 'originalRingerMode';
const String kBackgroundPortName = 'background_port';

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
  Timer? _refreshTimer;

  bool _isSelectionMode = false;
  Set<int> _selectedIndexes = {};

  @override
  void initState() {
    super.initState();
    _initApp();

    // 1분마다 UI 갱신 (시간 경과 체크용)
    _refreshTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (mounted) setState(() {});
    });

    IsolateNameServer.registerPortWithName(_receivePort.sendPort, kBackgroundPortName);
    _receivePort.listen((message) {
      _loadSchedules();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
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
    // 1. 방해 금지 모드
    var dndStatus = await Permission.accessNotificationPolicy.status;
    if (dndStatus.isDenied && mounted) {
      await _showPermissionDialog(
        title: '방해 금지 접근 권한 필요',
        content: '소리/진동/무음 모드 변경을 위해 권한이 필요합니다.',
        onAllow: () async => await Permission.accessNotificationPolicy.request(),
        onDeny: () => SystemNavigator.pop(),
      );
    }

    // 2. 정확한 알람
    var alarmStatus = await Permission.scheduleExactAlarm.status;
    if (alarmStatus.isDenied && mounted) {
      await _showPermissionDialog(
          title: '정확한 알림 사용 권한 필요',
          content: '지정한 시간에 정확히 모드를 변경하기 위해 권한이 필요합니다.',
          onAllow: () async => await Permission.scheduleExactAlarm.request(),
          onDeny: () {});
    }

    // 3. [보강] 배터리 최적화 예외 요청 (안드로이드 시스템이 앱을 죽이는 것 방지)
    var batteryStatus = await Permission.ignoreBatteryOptimizations.status;
    if (batteryStatus.isDenied && mounted) {
      await Permission.ignoreBatteryOptimizations.request();
    }

    // 4. [보강] 알림 권한 요청 (Android 13+)
    var notificationStatus = await Permission.notification.status;
    if (notificationStatus.isDenied && mounted) {
      await Permission.notification.request();
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
          TextButton(onPressed: () { Navigator.of(context).pop(); onDeny(); }, child: const Text('허용 안함')),
          TextButton(onPressed: () { Navigator.of(context).pop(); onAllow(); }, child: const Text('허용')),
        ],
      ),
    );
  }

  Future<void> _loadSchedules() async {
    final List<String> scheduleStrings = _prefs.getStringList(kScheduleListKey) ?? [];
    setState(() {
      try {
        _schedules = scheduleStrings.map((s) => Schedule.fromJson(jsonDecode(s))).toList();
      } catch (e) {
        _prefs.remove(kScheduleListKey);
        _schedules = [];
      }
    });
  }

  Future<void> _saveSchedules() async {
    final List<String> scheduleStrings = _schedules.map((s) => jsonEncode(s.toJson())).toList();
    await _prefs.setStringList(kScheduleListKey, scheduleStrings);
  }

  // [알람 등록 로직]
  Future<void> _scheduleAlarm(Schedule schedule) async {
    await _cancelAlarm(schedule, quiet: true);
    if (!schedule.isActive) return;

    List<int> targetDays = schedule.days.isEmpty ? [schedule.startTime.weekday] : schedule.days;
    bool isOneShot = schedule.days.isEmpty;
    String endModeParam = schedule.endMode?.name ?? 'original';
    String startModeParam = schedule.startMode.name;

    if (isOneShot) {
      final int baseId = schedule.hashCode.abs() & 0x3FFFFFFF;
      await AndroidAlarmManager.oneShotAt(
        schedule.startTime, baseId, setScheduledModeCallback,
        params: {'mode': startModeParam, 'msg': schedule.message},
        alarmClock: true, wakeup: true, rescheduleOnReboot: true,
      );
      await AndroidAlarmManager.oneShotAt(
        schedule.endTime, baseId + 1, revertToOriginalModeCallback,
        params: {'endMode': endModeParam, 'expectedStartMode': startModeParam, 'msg': schedule.message},
        alarmClock: true, wakeup: true, rescheduleOnReboot: true,
      );
    } else {
      for (int day in targetDays) {
        final int baseId = schedule.hashCode.abs() & 0x3FFFFFFF;
        final int startAlarmId = baseId + (day * 10);
        final int endAlarmId = baseId + (day * 10) + 1;

        DateTime nextStart = _nextInstanceOf(day, schedule.startTime.hour, schedule.startTime.minute);
        int durationMinutes = (schedule.endTime.hour * 60 + schedule.endTime.minute) - (schedule.startTime.hour * 60 + schedule.startTime.minute);
        if (durationMinutes < 0) durationMinutes += 24 * 60;
        DateTime nextEnd = nextStart.add(Duration(minutes: durationMinutes));

        await AndroidAlarmManager.periodic(
          const Duration(days: 7), startAlarmId, setScheduledModeCallback,
          startAt: nextStart, params: {'mode': startModeParam, 'msg': schedule.message},
          wakeup: true, rescheduleOnReboot: true,
        );
        await AndroidAlarmManager.periodic(
          const Duration(days: 7), endAlarmId, revertToOriginalModeCallback,
          startAt: nextEnd, params: {'endMode': endModeParam, 'expectedStartMode': startModeParam, 'msg': schedule.message},
          wakeup: true, rescheduleOnReboot: true,
        );
      }
    }
  }

  DateTime _nextInstanceOf(int weekday, int hour, int minute) {
    DateTime now = DateTime.now();
    DateTime scheduledDate = DateTime(now.year, now.month, now.day, hour, minute);
    int daysDiff = weekday - now.weekday;
    if (daysDiff < 0) scheduledDate = scheduledDate.add(Duration(days: daysDiff + 7));
    else if (daysDiff > 0) scheduledDate = scheduledDate.add(Duration(days: daysDiff));
    else if (scheduledDate.isBefore(now)) scheduledDate = scheduledDate.add(const Duration(days: 7));
    return scheduledDate;
  }

  Future<void> _cancelAlarm(Schedule schedule, {bool quiet = false}) async {
    final int baseId = schedule.hashCode.abs() & 0x3FFFFFFF;
    await AndroidAlarmManager.cancel(baseId);
    await AndroidAlarmManager.cancel(baseId + 1);
    for (int day = 1; day <= 7; day++) {
      await AndroidAlarmManager.cancel(baseId + (day * 10));
      await AndroidAlarmManager.cancel(baseId + (day * 10) + 1);
    }
  }

  Future<void> _stopRunningSchedule(Schedule schedule) async {
    await _cancelAlarm(schedule);
    String? originalModeName = _prefs.getString(kOriginalRingerModeKey);
    if (originalModeName != null) {
      RingerModeStatus targetMode;
      if (originalModeName == 'vibrate') targetMode = RingerModeStatus.vibrate;
      else if (originalModeName == 'sound' || originalModeName == 'normal') targetMode = RingerModeStatus.normal;
      else targetMode = RingerModeStatus.silent;
      await SoundMode.setSoundMode(targetMode);
    } else {
      await SoundMode.setSoundMode(RingerModeStatus.normal);
    }
    await _prefs.remove(kOriginalRingerModeKey);
  }

  Future<void> _deleteSelectedSchedules() async {
    final List<int> indexesToRemove = _selectedIndexes.toList()..sort((a, b) => b.compareTo(a));
    for (int index in indexesToRemove) {
      Schedule schedule = _schedules[index];
      if (_checkIsRunning(schedule)) {
        await _stopRunningSchedule(schedule);
      } else {
        await _cancelAlarm(schedule);
      }
      _schedules.removeAt(index);
    }
    await _saveSchedules();
    setState(() {
      _isSelectionMode = false;
      _selectedIndexes.clear();
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedIndexes.length == _schedules.length) _selectedIndexes.clear();
      else _selectedIndexes = Set.from(List.generate(_schedules.length, (index) => index));
    });
  }

  bool _checkIsRunning(Schedule schedule) {
    if (!schedule.isActive) return false;
    final now = DateTime.now();
    if (schedule.days.isEmpty) return now.isAfter(schedule.startTime) && now.isBefore(schedule.endTime);

    int nowMinutes = now.hour * 60 + now.minute;
    int startMinutes = schedule.startTime.hour * 60 + schedule.startTime.minute;
    int endMinutes = schedule.endTime.hour * 60 + schedule.endTime.minute;
    bool crossesMidnight = endMinutes <= startMinutes;
    if (crossesMidnight) endMinutes += 24 * 60;

    if (schedule.days.contains(now.weekday)) {
      if (nowMinutes >= startMinutes && nowMinutes < endMinutes) return true;
    }
    if (crossesMidnight) {
      int yesterday = now.weekday - 1;
      if (yesterday < 1) yesterday = 7;
      if (schedule.days.contains(yesterday)) {
        int nowMinutesShifted = nowMinutes + 24 * 60;
        if (nowMinutesShifted >= startMinutes && nowMinutesShifted < endMinutes) return true;
      }
    }
    return false;
  }

  bool _checkOverlapWithActive(Schedule targetSchedule) {
    for (var existing in _schedules) {
      if (existing == targetSchedule) continue;
      if (!existing.isActive) continue;
      if (existing.days.isEmpty && existing.endTime.isBefore(DateTime.now())) continue;

      if (targetSchedule.days.isEmpty && existing.days.isEmpty) {
        if (existing.startTime.isBefore(targetSchedule.endTime) && existing.endTime.isAfter(targetSchedule.startTime)) return true;
        continue;
      }

      List<int> checkDaysNew = targetSchedule.days.isEmpty ? [targetSchedule.startTime.weekday] : targetSchedule.days;
      List<int> checkDaysEx = existing.days.isEmpty ? [existing.startTime.weekday] : existing.days;

      bool dayOverlap = false;
      for (var day in checkDaysNew) {
        if (checkDaysEx.contains(day)) {
          dayOverlap = true;
          break;
        }
      }
      if (!dayOverlap) continue;

      int newStartMins = targetSchedule.startTime.hour * 60 + targetSchedule.startTime.minute;
      int newEndMins = targetSchedule.endTime.hour * 60 + targetSchedule.endTime.minute;
      if (newEndMins <= newStartMins) newEndMins += 24 * 60;

      int exStartMins = existing.startTime.hour * 60 + existing.startTime.minute;
      int exEndMins = existing.endTime.hour * 60 + existing.endTime.minute;
      if (exEndMins <= exStartMins) exEndMins += 24 * 60;

      if (exStartMins < newEndMins && exEndMins > newStartMins) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (_isSelectionMode) {
          setState(() {
            _isSelectionMode = false;
            _selectedIndexes.clear();
          });
          return false;
        }
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _isSelectionMode
              ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() { _isSelectionMode = false; _selectedIndexes.clear(); }))
              : null,
          title: _isSelectionMode
              ? Row(children: [
            Checkbox(
              value: _selectedIndexes.length == _schedules.length && _schedules.isNotEmpty,
              onChanged: (bool? value) => _toggleSelectAll(),
              fillColor: MaterialStateProperty.all(Colors.blue), checkColor: Colors.white,
            ),
            const SizedBox(width: 8),
            Text('전체 선택      ${_selectedIndexes.length}개 선택됨', style: const TextStyle(fontSize: 18)),
          ])
              : const Text('소리/진동 제어'),
          actions: [
            if (_isSelectionMode)
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: _selectedIndexes.isEmpty ? null : () async {
                  bool hasRunning = false;
                  for (int index in _selectedIndexes) {
                    if (_checkIsRunning(_schedules[index])) {
                      hasRunning = true;
                      break;
                    }
                  }
                  String dialogTitle = '선택한 일정 삭제';
                  String dialogContent = '${_selectedIndexes.length}개의 일정을 삭제하시겠습니까?';
                  if (hasRunning) dialogContent = '선택한 일정 중 현재 실행 중인 항목이 있습니다.\n\n삭제 시 기능이 종료되고 원래 소리 설정으로 복구됩니다.\n\n계속하시겠습니까?';

                  final bool? confirm = await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(dialogTitle),
                      content: Text(dialogContent),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('취소')),
                        TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(hasRunning ? '종료 및 삭제' : '삭제', style: const TextStyle(color: Colors.red))),
                      ],
                    ),
                  );
                  if (confirm == true) await _deleteSelectedSchedules();
                },
              ),
          ],
        ),
        body: _isLoading ? const Center(child: CircularProgressIndicator()) : _schedules.isEmpty ? _buildEmptyState() : _buildScheduleList(),
        floatingActionButton: _isSelectionMode ? null : FloatingActionButton(
          onPressed: () async {
            final newSchedule = await Navigator.push<Schedule>(
              context, MaterialPageRoute(builder: (context) => AddSchedulePage(existingSchedules: _schedules)),
            );
            if (newSchedule != null) {
              setState(() { _schedules.add(newSchedule); });
              await _saveSchedules();
              await _scheduleAlarm(newSchedule);
            }
          },
          backgroundColor: Colors.blue, child: const Icon(Icons.add, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(child: Text('설정된 기간이 없습니다', style: TextStyle(fontSize: 18, color: Colors.grey)));
  }

  Widget _buildScheduleList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _schedules.length,
      itemBuilder: (context, index) {
        final schedule = _schedules[index];
        final isSelected = _selectedIndexes.contains(index);
        final now = DateTime.now();
        final bool isOneShot = schedule.days.isEmpty;
        final bool isRunning = _checkIsRunning(schedule);
        final bool isExpiredOneShot = isOneShot && now.isAfter(schedule.endTime);
        final bool isInactiveOrExpired = !schedule.isActive || isExpiredOneShot;

        final Color titleColor = isInactiveOrExpired ? Colors.grey : Colors.black;
        final Color timeColor = isInactiveOrExpired ? Colors.grey : Colors.grey[700]!;
        final Color accentColor = isInactiveOrExpired ? Colors.grey : Colors.blue;
        final Color subInfoColor = isInactiveOrExpired ? Colors.grey : Colors.grey[700]!;

        String daysString;
        if (isOneShot) daysString = "${schedule.startTime.year}.${schedule.startTime.month}.${schedule.startTime.day} (단발성)";
        else daysString = schedule.days.map((d) { const days = ['월', '화', '수', '목', '금', '토', '일']; return days[d - 1]; }).join(', ');

        String endModeText = '원래대로';
        if (schedule.endMode == SoundModeEnum.sound) endModeText = "소리";
        if (schedule.endMode == SoundModeEnum.vibrate) endModeText = "진동";
        if (schedule.endMode == SoundModeEnum.silent) endModeText = "무음";

        String modeDisplayText = '시작: ${schedule.startMode.displayName}  ➜  종료: $endModeText';

        Color cardColor;
        if (isSelected) cardColor = Colors.blue.withAlpha(30);
        else if (isRunning) cardColor = Colors.grey.shade200;
        else cardColor = Colors.white;

        Widget cardContent = Card(
          elevation: isInactiveOrExpired ? 0 : 2,
          margin: const EdgeInsets.symmetric(vertical: 8),
          color: cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: isSelected ? const BorderSide(color: Colors.blue, width: 2) : BorderSide.none),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            leading: _isSelectionMode ? Checkbox(value: isSelected, onChanged: (bool? value) { setState(() { if (value == true) _selectedIndexes.add(index); else _selectedIndexes.remove(index); }); }) : null,
            title: Row(children: [
              Expanded(child: Text(schedule.message, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: titleColor))),
              if (isRunning) Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(8)),
                child: const Text("RUNNING", style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ]),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: 8),
              Text('${schedule.startTime.hour.toString().padLeft(2, '0')}:${schedule.startTime.minute.toString().padLeft(2, '0')} - ${schedule.endTime.hour.toString().padLeft(2, '0')}:${schedule.endTime.minute.toString().padLeft(2, '0')}', style: TextStyle(color: timeColor, fontWeight: FontWeight.bold)),
              Text('반복: $daysString', style: TextStyle(color: accentColor)),
              const SizedBox(height: 4),
              Text(modeDisplayText, style: TextStyle(color: subInfoColor)),
            ]),
            onTap: () async {
              if (_isSelectionMode) {
                setState(() { if (isSelected) _selectedIndexes.remove(index); else _selectedIndexes.add(index); });
              } else {
                final updatedSchedule = await Navigator.push<Schedule>(context, MaterialPageRoute(builder: (context) => AddSchedulePage(scheduleToEdit: schedule, existingSchedules: _schedules)));
                if (updatedSchedule != null) {
                  await _cancelAlarm(schedule);
                  setState(() { _schedules[index] = updatedSchedule; });
                  await _saveSchedules();
                  await _scheduleAlarm(updatedSchedule);
                }
              }
            },
            onLongPress: () {
              if (!_isSelectionMode) { setState(() { _isSelectionMode = true; _selectedIndexes.add(index); }); HapticFeedback.vibrate(); }
            },
            trailing: _isSelectionMode ? null : Switch(
              value: schedule.isActive,
              activeColor: isInactiveOrExpired ? Colors.grey : Colors.blue,
              onChanged: (value) async {
                if (value) {
                  if (_checkOverlapWithActive(schedule)) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("다른 활성화된 일정과 시간이 겹쳐서 켤 수 없습니다.")));
                    return;
                  }
                  setState(() { schedule.isActive = true; });
                  await _saveSchedules();
                  await _scheduleAlarm(schedule);
                } else {
                  if (isRunning) {
                    bool? confirm = await showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text("실행 중인 일정"),
                        content: const Text("현재 실행 중인 기능입니다.\n종료하시겠습니까? (원래 설정으로 돌아갑니다)"),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("아니요")),
                          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("네", style: TextStyle(color: Colors.red))),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await _stopRunningSchedule(schedule);
                      setState(() { schedule.isActive = false; });
                      await _saveSchedules();
                    }
                  } else {
                    setState(() { schedule.isActive = false; });
                    await _saveSchedules();
                    await _cancelAlarm(schedule);
                  }
                }
              },
            ),
          ),
        );
        if (isInactiveOrExpired) return Opacity(opacity: 0.6, child: cardContent);
        else return cardContent;
      },
    );
  }
}