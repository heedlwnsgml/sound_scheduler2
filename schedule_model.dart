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

class Schedule {
  final DateTime startTime;
  final DateTime endTime;
  final SoundModeEnum startMode;
  final SoundModeEnum? endMode; // Null = 원래대로
  final String message;
  final List<int> days;
  bool isActive;

  Schedule({
    required this.startTime,
    required this.endTime,
    required this.startMode,
    this.endMode,
    required this.message,
    required this.days,
    this.isActive = true,
  });

  Map<String, dynamic> toJson() => {
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'mode': startMode.name,
        'endMode': endMode?.name,
        'message': message,
        'days': days,
        'isActive': isActive,
      };

  factory Schedule.fromJson(Map<String, dynamic> json) => Schedule(
        startTime: DateTime.parse(json['startTime']),
        endTime: DateTime.parse(json['endTime']),
        startMode: SoundModeEnum.values.firstWhere(
            (e) => e.name == json['mode'],
            orElse: () => SoundModeEnum.silent),
        endMode: json['endMode'] != null
            ? SoundModeEnum.values.firstWhere((e) => e.name == json['endMode'],
                orElse: () => SoundModeEnum.silent)
            : null,
        message: json['message'],
        days: List<int>.from(json['days']),
        isActive: json['isActive'],
      );
}
