import 'package:flutter/material.dart';

const bookingInk = Color(0xFF163E43);
const bookingTeal = Color(0xFF006877);

IconData facilityIcon(String name) {
  final value = name.toLowerCase();
  if (value.contains('pool') || value.contains('swim')) return Icons.pool;
  if (value.contains('tennis') || value.contains('badminton')) {
    return Icons.sports_tennis;
  }
  if (value.contains('basket')) return Icons.sports_basketball_outlined;
  if (value.contains('court')) return Icons.sports_soccer_outlined;
  if (value.contains('suite')) return Icons.bed_outlined;
  if (value.contains('meeting') || value.contains('conference')) {
    return Icons.groups_outlined;
  }
  if (value.contains('workspace')) return Icons.work_outline;
  return Icons.spa_outlined;
}

String friendlyDate(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

class BookingIntro extends StatelessWidget {
  const BookingIntro({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF006877), Color(0xFF003F49)],
      ),
      borderRadius: BorderRadius.circular(28),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.spa_outlined, color: Color(0xFFB8E5D5), size: 18),
            SizedBox(width: 8),
            Flexible(
              child: Text(
                'YOUR CLUB. YOUR TIME.',
                style: TextStyle(
                  color: Color(0xFFB8E5D5),
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Make time\nfor yourself.',
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            height: 1.15,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'A space to move. A moment to unwind.',
          style: TextStyle(color: Color(0xFFD6E7E5), height: 1.6),
        ),
      ],
    ),
  );
}

class BookingSection extends StatelessWidget {
  const BookingSection({
    super.key,
    required this.number,
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String number, title, subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0xAFFFFFFF),
      border: Border.all(color: const Color(0xDDFFFFFF)),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFEDF4F1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                number,
                style: const TextStyle(
                  color: bookingTeal,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: bookingInk,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF687C7D),
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        child,
      ],
    ),
  );
}

class FacilityCards extends StatelessWidget {
  const FacilityCards({
    super.key,
    required this.resources,
    required this.selectedId,
    required this.onSelected,
  });
  final List<Map<String, dynamic>> resources;
  final String selectedId;
  final ValueChanged<Map<String, dynamic>>? onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.textScalerOf(context).scale(166),
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: resources.length,
      separatorBuilder: (_, index) => const SizedBox(width: 10),
      itemBuilder: (context, index) {
        final resource = resources[index];
        final active = resource['id'] == selectedId;
        return Semantics(
          selected: active,
          child: SizedBox(
            width: MediaQuery.textScalerOf(context).scale(168),
            child: Material(
              color: active ? bookingInk : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: BorderSide(
                  color: active ? bookingInk : const Color(0xFFE4EBE8),
                  width: active ? 1.5 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onSelected == null ? null : () => onSelected!(resource),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            facilityIcon(resource['name']),
                            color: active
                                ? const Color(0xFFB8E5D5)
                                : bookingTeal,
                            size: 32,
                          ),
                          const Spacer(),
                          if (active)
                            const Icon(
                              Icons.check_circle,
                              color: Color(0xFFB8E5D5),
                              size: 18,
                            ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        resource['name'],
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: active ? Colors.white : bookingInk,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        resource['preferred_unit'] == 'daily'
                            ? 'Day reservations'
                            : 'Flexible sessions',
                        style: TextStyle(
                          fontSize: 11,
                          color: active
                              ? const Color(0xFFC7DBD5)
                              : const Color(0xFF687C7D),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class BookingDates extends StatelessWidget {
  const BookingDates({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.onCalendar,
  });
  final DateTime selected;
  final ValueChanged<DateTime>? onSelected;
  final VoidCallback? onCalendar;

  @override
  Widget build(BuildContext context) {
    final now = DateUtils.dateOnly(DateTime.now());
    final start = selected.isBefore(now.add(const Duration(days: 7)))
        ? now
        : selected;
    const weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                friendlyDate(selected),
                style: const TextStyle(
                  color: bookingInk,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: onCalendar,
              icon: const Icon(Icons.calendar_month_outlined, size: 17),
              label: const Text('Calendar'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: MediaQuery.textScalerOf(context).scale(84),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount:
                (now
                            .add(const Duration(days: 365))
                            .difference(DateUtils.dateOnly(start))
                            .inDays +
                        1)
                    .clamp(1, 7),
            separatorBuilder: (_, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final date = start.add(Duration(days: index));
              final active = DateUtils.isSameDay(date, selected);
              return SizedBox(
                width: MediaQuery.textScalerOf(context).scale(58),
                child: Material(
                  color: active ? bookingInk : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onSelected == null ? null : () => onSelected!(date),
                    child: Semantics(
                      label: friendlyDate(date),
                      selected: active,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            weekdays[date.weekday - 1],
                            style: TextStyle(
                              color: active
                                  ? Colors.white70
                                  : const Color(0xFF687C7D),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${date.day}',
                            style: TextStyle(
                              color: active ? Colors.white : bookingInk,
                              fontSize: 23,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Icon(
                            Icons.circle,
                            size: 4,
                            color: active
                                ? const Color(0xFFB8E5D5)
                                : Colors.transparent,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
