import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sound_mode/sound_mode.dart';
import 'package:sound_mode/utils/ringer_mode_statuses.dart';

const String kOriginalRingerModeKey = 'originalRingerMode';
const String kBackgroundPortName = 'background_port';

// 알림 플러그인 인스턴스
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
FlutterLocalNotificationsPlugin();

// [알림 초기화 및 발송 함수]
Future<void> _showNotification(String title, String body) async {
  // 백그라운드에서도 초기화 필요
  const AndroidInitializationSettings initializationSettingsAndroid =
  AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings =
  InitializationSettings(android: initializationSettingsAndroid);

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'sound_scheduler_channel', // 채널 ID
    'Sound Scheduler 알림', // 채널 이름
    channelDescription: '소리 모드 변경 알림',
    importance: Importance.high,
    priority: Priority.high,
  );

  const NotificationDetails platformDetails =
  NotificationDetails(android: androidDetails);

  await flutterLocalNotificationsPlugin.show(
    DateTime.now().millisecond, // 유니크 ID
    title,
    body,
    platformDetails,
  );
}

// [모드 변경 헬퍼]
Future<void> _setDeviceMode(String modeName) async {
  RingerModeStatus targetMode;
  if (modeName == 'vibrate') {
    targetMode = RingerModeStatus.vibrate;
  } else if (modeName == 'sound' || modeName == 'normal') {
    targetMode = RingerModeStatus.normal;
  } else {
    targetMode = RingerModeStatus.silent;
  }

  try {
    await SoundMode.setSoundMode(targetMode);
    print("[시스템] 모드 변경 요청 수행됨: $modeName");
  } catch (e) {
    print("[오류] 모드 변경 실패: $e");
  }
}

// [1. 시작 시간 콜백]
@pragma('vm:entry-point')
void setScheduledModeCallback(int id, Map<String, dynamic> params) async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences prefs = await SharedPreferences.getInstance();

  final String modeToSet = params['mode'] as String? ?? 'silent';
  final String message = params['msg'] as String? ?? '스케줄 실행';

  try {
    // 현재 상태 백업
    RingerModeStatus currentMode = await SoundMode.ringerModeStatus;
    await prefs.setString(kOriginalRingerModeKey, currentMode.name);

    // 모드 변경
    await _setDeviceMode(modeToSet);

    // [보강] 알림 발송
    await _showNotification("모드 변경됨", "$message: $modeToSet 모드로 변경되었습니다.");

  } catch (e) {
    print("시작 콜백 오류: $e");
  }

  final SendPort? sendPort = IsolateNameServer.lookupPortByName(kBackgroundPortName);
  if (sendPort != null) sendPort.send({'id': id, 'status': 'started'});
}

// [2. 종료 시간 콜백]
@pragma('vm:entry-point')
void revertToOriginalModeCallback(int id, Map<String, dynamic> params) async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences prefs = await SharedPreferences.getInstance();

  final String endModeSetting = params['endMode'] as String? ?? 'original';
  final String expectedStartMode = params['expectedStartMode'] as String? ?? '';
  final String message = params['msg'] as String? ?? '스케줄 종료';

  try {
    // 사용자 임의 변경 감지 로직
    RingerModeStatus currentStatusEnum = await SoundMode.ringerModeStatus;
    String currentStatus = currentStatusEnum.name;
    bool isChangedByUser = false;

    if (expectedStartMode.isNotEmpty) {
      String normalizedExpected = (expectedStartMode == 'sound') ? 'normal' : expectedStartMode;
      String normalizedCurrent = (currentStatus == 'sound') ? 'normal' : currentStatus;

      if (normalizedExpected != normalizedCurrent) {
        isChangedByUser = true;
      }
    }

    if (isChangedByUser) {
      // [보강] 사용자가 변경해서 복구하지 않음을 알림
      await _showNotification("설정 유지됨", "사용자가 소리 설정을 변경하여, 앱 설정을 적용하지 않고 종료합니다.");
      await prefs.remove(kOriginalRingerModeKey);
    } else {
      // 정상 복구
      if (endModeSetting == 'original') {
        String? originalModeName = prefs.getString(kOriginalRingerModeKey);
        if (originalModeName != null) {
          await _setDeviceMode(originalModeName);
          await _showNotification("모드 복구됨", "$message: 원래 설정($originalModeName)으로 복구되었습니다.");
        }
        await prefs.remove(kOriginalRingerModeKey);
      } else {
        await _setDeviceMode(endModeSetting);
        await _showNotification("모드 변경됨", "$message: 종료 설정($endModeSetting)으로 변경되었습니다.");
        await prefs.remove(kOriginalRingerModeKey);
      }
    }
  } catch (e) {
    print("종료 콜백 오류: $e");
  }

  final SendPort? sendPort = IsolateNameServer.lookupPortByName(kBackgroundPortName);
  if (sendPort != null) sendPort.send({'id': id, 'status': 'ended'});
}