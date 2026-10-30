import 'dart:async';

import 'package:flutter/material.dart';

import 'booking_design.dart';

class SlotPicker extends StatefulWidget {
  const SlotPicker({
    super.key,
    required this.load,
    required this.onSelected,
    required this.selected,
    required this.locked,
  });
  final Future<dynamic> Function() load;
  final ValueChanged<int> onSelected;
  final int selected;
  final bool locked;
  @override
  State<SlotPicker> createState() => _SlotPickerState();
}

class _SlotPickerState extends State<SlotPicker> {
  final states = <int, String>{};
  Timer? timer;
  bool loading = false;
  bool failed = false;
  late int period;
  @override
  void initState() {
    super.initState();
    period = widget.selected ~/ 360;
    refresh();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      final data = await widget.load();
      if (mounted) {
        setState(() {
          failed = false;
          states.clear();
          for (final slot in data['slots']) {
            states[slot['minute'] as int] = slot['status'] as String;
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          failed = true;
          for (var minute = 0; minute < 1440; minute += 30) {
            states[minute] = 'Unavailable';
          }
        });
      }
    }
    if (mounted) setState(() => loading = false);
  }

  String time(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) => BookingSection(
    number: '03',
    title: 'Choose your time',
    subtitle: 'Live availability for your selected duration.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: List.generate(4, (position) {
              final index = const [1, 2, 3, 0][position];
              const names = ['Night', 'Morning', 'Afternoon', 'Evening'];
              const icons = [
                Icons.nightlight_outlined,
                Icons.wb_twilight,
                Icons.light_mode_outlined,
                Icons.dark_mode_outlined,
              ];
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(names[index]),
                  avatar: Icon(icons[index], size: 16),
                  selected: period == index,
                  showCheckmark: false,
                  selectedColor: const Color(0xFFDDEFE8),
                  onSelected: (_) => setState(() => period = index),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Icon(Icons.circle, size: 7, color: Color(0xFF16804A)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                failed
                    ? 'Couldn’t load availability'
                    : loading
                    ? 'Checking availability…'
                    : '${states.entries.where((entry) => entry.key ~/ 360 == period && entry.value == 'Available').length} times available',
                style: const TextStyle(fontSize: 12, color: Color(0xFF687C7D)),
              ),
            ),
            IconButton(
              tooltip: 'Refresh availability',
              onPressed: loading ? null : refresh,
              icon: const Icon(Icons.refresh, size: 19),
            ),
          ],
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < 280 ? 2 : 3;
            final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(12, (index) {
                final slot = period * 360 + index * 30;
                final status = states[slot] ?? 'Checking';
                final selected =
                    widget.selected == slot && status == 'Available';
                final available = status == 'Available';
                return SizedBox(
                  width: width,
                  child: Semantics(
                    selected: selected,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 4,
                        ),
                        minimumSize: const Size(0, 60),
                        backgroundColor: selected
                            ? bookingTeal
                            : available
                            ? const Color(0xFFF3F8F5)
                            : const Color(0xFFF6F7F6),
                        foregroundColor: selected ? Colors.white : bookingInk,
                        disabledForegroundColor: const Color(0xFF87928F),
                        side: BorderSide(
                          color: selected
                              ? bookingTeal
                              : available
                              ? const Color(0xFFD4E5DD)
                              : const Color(0xFFEBEFEC),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      onPressed: widget.locked || !available
                          ? null
                          : () => widget.onSelected(slot),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            time(slot),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            selected ? 'Selected ✓' : status,
                            style: const TextStyle(fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            );
          },
        ),
        const SizedBox(height: 16),
        if (widget.selected ~/ 360 != period &&
            states[widget.selected] == 'Available')
          Text(
            'Selected start: ${time(widget.selected)}',
            style: const TextStyle(
              color: bookingTeal,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        const Text(
          'Booked and unavailable times cannot be selected.',
          style: TextStyle(fontSize: 11, color: Color(0xFF687C7D), height: 1.5),
        ),
      ],
    ),
  );
}
