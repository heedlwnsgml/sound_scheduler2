import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../models/schedule_model.dart';

class AddSchedulePage extends StatefulWidget {
  final Schedule? scheduleToEdit;
  final List<Schedule>? existingSchedules;

  const AddSchedulePage({super.key, this.scheduleToEdit, this.existingSchedules});

  @override
  State<AddSchedulePage> createState() => _AddSchedulePageState();
}

class _AddSchedulePageState extends State<AddSchedulePage> {
  late TextEditingController _startHourController;
  late TextEditingController _startMinuteController;
  late TextEditingController _endHourController;
  late TextEditingController _endMinuteController;
  late TextEditingController _messageController;

  DateTime _selectedDate = DateTime.now();
  SoundModeEnum _selectedStartMode = SoundModeEnum.silent;
  bool _useCustomEndMode = false;
  SoundModeEnum _selectedEndMode = SoundModeEnum.sound;
  Set<int> _selectedDays = {};

  @override
  void initState() {
    super.initState();
    if (widget.scheduleToEdit != null) {
      final s = widget.scheduleToEdit!;
      _startHourController = TextEditingController(text: s.startTime.hour.toString());
      _startMinuteController = TextEditingController(text: s.startTime.minute.toString());
      _endHourController = TextEditingController(text: s.endTime.hour.toString());
      _endMinuteController = TextEditingController(text: s.endTime.minute.toString());
      _messageController = TextEditingController(text: s.message);
      _selectedDate = s.startTime;
      _selectedStartMode = s.startMode;
      if (s.endMode == null) {
        _useCustomEndMode = false;
        _selectedEndMode = SoundModeEnum.sound;
      } else {
        _useCustomEndMode = true;
        _selectedEndMode = s.endMode!;
      }
      _selectedDays = s.days.toSet();
    } else {
      final now = DateTime.now();
      _selectedDate = now;
      final endTime = now.add(const Duration(hours: 1));
      _startHourController = TextEditingController(text: now.hour.toString());
      _startMinuteController = TextEditingController(text: now.minute.toString());
      _endHourController = TextEditingController(text: endTime.hour.toString());
      _endMinuteController = TextEditingController(text: endTime.minute.toString());
      _messageController = TextEditingController(text: "회의");
    }
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

  bool _isTimeOverlap(DateTime newStart, DateTime newEnd, List<int> newDays, List<Schedule> existing) {
    final now = DateTime.now();
    for (var schedule in existing) {
      if (widget.scheduleToEdit != null && schedule == widget.scheduleToEdit) continue;
      if (!schedule.isActive) continue;
      if (schedule.days.isEmpty && schedule.endTime.isBefore(now)) continue;

      if (newDays.isEmpty && schedule.days.isEmpty) {
        if (schedule.startTime.isBefore(newEnd) && schedule.endTime.isAfter(newStart)) return true;
        continue;
      }

      List<int> checkDaysNew = newDays.isEmpty ? [newStart.weekday] : newDays;
      List<int> checkDaysEx = schedule.days.isEmpty ? [schedule.startTime.weekday] : schedule.days;

      bool dayOverlap = false;
      for (var day in checkDaysNew) {
        if (checkDaysEx.contains(day)) {
          dayOverlap = true;
          break;
        }
      }
      if (!dayOverlap) continue;

      final int newStartMins = newStart.hour * 60 + newStart.minute;
      int newEndMins = newEnd.hour * 60 + newEnd.minute;
      if (newEndMins <= newStartMins) newEndMins += 24 * 60;

      final int exStartMins = schedule.startTime.hour * 60 + schedule.startTime.minute;
      int exEndMins = schedule.endTime.hour * 60 + schedule.endTime.minute;
      if (exEndMins <= exStartMins) exEndMins += 24 * 60;

      if (exStartMins < newEndMins && exEndMins > newStartMins) return true;
    }
    return false;
  }

  void _saveSchedule() {
    final int startHour = int.tryParse(_startHourController.text) ?? -1;
    final int startMinute = int.tryParse(_startMinuteController.text) ?? -1;
    final int endHour = int.tryParse(_endHourController.text) ?? -1;
    final int endMinute = int.tryParse(_endMinuteController.text) ?? -1;

    if (startHour < 0 || startHour > 23 || startMinute < 0 || startMinute > 59 ||
        endHour < 0 || endHour > 23 || endMinute < 0 || endMinute > 59) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('시간을 올바르게 입력하세요.')));
      return;
    }

    DateTime startDateTime = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day, startHour, startMinute);
    DateTime endDateTime = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day, endHour, endMinute);

    if (endDateTime.isBefore(startDateTime) || endDateTime.isAtSameMomentAs(startDateTime)) {
      endDateTime = endDateTime.add(const Duration(days: 1));
    }

    if (widget.existingSchedules != null) {
      if (_isTimeOverlap(startDateTime, endDateTime, _selectedDays.toList(), widget.existingSchedules!)) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('시간 중복 경고'),
            content: const Text('설정한 시간대에 이미 다른 일정이 존재합니다.'),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('확인'))],
          ),
        );
        return;
      }
    }

    final newSchedule = Schedule(
      startTime: startDateTime,
      endTime: endDateTime,
      startMode: _selectedStartMode,
      endMode: _useCustomEndMode ? _selectedEndMode : null,
      message: _messageController.text.isEmpty ? '이름 없음' : _messageController.text,
      days: _selectedDays.toList()..sort(),
      isActive: true,
    );

    Navigator.of(context).pop(newSchedule);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        title: Text(widget.scheduleToEdit == null ? '새 일정 추가' : '일정 수정'),
        actions: [
          TextButton(
            onPressed: _saveSchedule,
            child: const Text('저장', style: TextStyle(color: Colors.blue, fontSize: 18, fontWeight: FontWeight.bold)),
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
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 24),
            _buildDateSelector(),
            const SizedBox(height: 24),
            _buildDateTimeSelection(),
            const SizedBox(height: 24),
            _buildDaySelector(),
            const SizedBox(height: 24),
            const Text('모드 선택', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            _buildStartModeSelector(),
            const SizedBox(height: 20),
            _buildEndModeSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildDateSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('날짜 선택 (반복 요일 미선택 시 적용)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        InkWell(
          onTap: () async {
            final DateTime? picked = await showDatePicker(
              context: context,
              initialDate: _selectedDate,
              firstDate: DateTime(2020),
              lastDate: DateTime(2030),
              locale: const Locale('ko', 'KR'),
            );
            if (picked != null) setState(() => _selectedDate = picked);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                const Icon(Icons.calendar_today, color: Colors.blue),
                const SizedBox(width: 10),
                Text(DateFormat('yyyy년 MM월 dd일 (E)', 'ko_KR').format(_selectedDate), style: const TextStyle(fontSize: 16)),
                const Spacer(),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDateTimeSelection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('시작 시간 (24시 기준)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _buildTimeField(_startHourController, '시 (0-23)')),
          const SizedBox(width: 10),
          Expanded(child: _buildTimeField(_startMinuteController, '분 (0-59)')),
        ]),
        const SizedBox(height: 16),
        const Text('종료 시간 (24시 기준)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _buildTimeField(_endHourController, '시 (0-23)')),
          const SizedBox(width: 10),
          Expanded(child: _buildTimeField(_endMinuteController, '분 (0-59)')),
        ]),
      ],
    );
  }

  Widget _buildTimeField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
    );
  }

  Widget _buildDaySelector() {
    final List<String> weekDays = ['월', '화', '수', '목', '금', '토', '일'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('반복 요일 (선택 시 날짜는 시작 기준일이 됨)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(7, (index) {
            final day = index + 1;
            final isSelected = _selectedDays.contains(day);
            return GestureDetector(
              onTap: () => setState(() => isSelected ? _selectedDays.remove(day) : _selectedDays.add(day)),
              child: CircleAvatar(
                radius: 20,
                backgroundColor: isSelected ? Colors.blue : Colors.grey[200],
                child: Text(weekDays[index], style: TextStyle(color: isSelected ? Colors.white : Colors.black, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildStartModeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('1. 시작 시 변경할 모드', style: TextStyle(fontSize: 14, color: Colors.grey)),
        const SizedBox(height: 5),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildModeOption(Icons.volume_up, '소리', SoundModeEnum.sound, true),
            _buildModeOption(Icons.vibration, '진동', SoundModeEnum.vibrate, true),
            _buildModeOption(Icons.volume_off, '무음', SoundModeEnum.silent, true),
          ],
        ),
      ],
    );
  }

  Widget _buildEndModeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('2. 종료 시 변경할 모드', style: TextStyle(fontSize: 14, color: Colors.grey)),
            Row(
              children: [
                Text(_useCustomEndMode ? "직접 선택" : "자동 복구", style: TextStyle(fontSize: 12, color: _useCustomEndMode ? Colors.blue : Colors.grey)),
                Switch(
                  value: _useCustomEndMode,
                  onChanged: (value) => setState(() => _useCustomEndMode = value),
                ),
              ],
            ),
          ],
        ),
        if (!_useCustomEndMode)
          const Padding(padding: EdgeInsets.all(8.0), child: Text("💡 시작 전 상태로 자동으로 되돌립니다.", style: TextStyle(color: Colors.grey))),
        if (_useCustomEndMode)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildModeOption(Icons.volume_up, '소리', SoundModeEnum.sound, false),
                _buildModeOption(Icons.vibration, '진동', SoundModeEnum.vibrate, false),
                _buildModeOption(Icons.volume_off, '무음', SoundModeEnum.silent, false),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildModeOption(IconData icon, String label, SoundModeEnum mode, bool isStartMode) {
    final bool isSelected = isStartMode ? _selectedStartMode == mode : _selectedEndMode == mode;
    return GestureDetector(
      onTap: () => setState(() => isStartMode ? _selectedStartMode = mode : _selectedEndMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue.withAlpha(26) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? Colors.blue : Colors.grey[300]!, width: 1.5),
        ),
        child: Column(
          children: [
            Icon(icon, color: isSelected ? Colors.blue : Colors.grey[600], size: 24),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 12, color: isSelected ? Colors.blue : Colors.grey[600], fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }
}