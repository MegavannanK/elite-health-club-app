import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:clerk_flutter/clerk_flutter.dart';

import 'auth_screen.dart';
import 'slot_picker.dart';
import 'booking_design.dart';

void main() {
  const key = String.fromEnvironment('CLERK_PUBLISHABLE_KEY');
  runApp(
    (key.isEmpty || kIsWeb)
        ? const ClubApp()
        : ClerkAuth(
            config: ClerkAuthConfig(publishableKey: key),
            child: const ClubApp(),
          ),
  );
}

const teal = Color(0xFF006877);
String day(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String clock(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
String clubTime(String value) {
  final d = DateTime.parse(value)
      .toUtc()
      .add(const Duration(hours: 5, minutes: 30));
  return '${day(d)} · ${clock(d.hour * 60 + d.minute)}';
}

class ClubApp extends StatelessWidget {
  const ClubApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Elite Health Club',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: '.SF Pro Text',
      fontFamilyFallback: const ['Helvetica Neue', 'Arial'],
      colorScheme: ColorScheme.fromSeed(seedColor: teal),
      scaffoldBackgroundColor: Colors.transparent,
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontFamily: '.SF Pro Display',
          fontSize: 32,
          color: Color(0xFF173D42),
          height: 1.15,
        ),
        headlineMedium: TextStyle(
          fontFamily: '.SF Pro Display',
          fontSize: 26,
          color: Color(0xFF173D42),
        ),
        titleLarge: TextStyle(
          fontFamily: '.SF Pro Display',
          fontSize: 22,
          color: Color(0xFF173D42),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xBFFFFFFF),
        indicatorColor: teal.withValues(alpha: 0.12),
        height: 72,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xCCFFFFFF),
        elevation: 8,
        shadowColor: const Color(0x15006877),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: Color(0xB3FFFFFF)),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          borderSide: BorderSide(color: Color(0xB3FFFFFF)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          borderSide: BorderSide(color: Color(0xB3FFFFFF)),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        filled: true,
        fillColor: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Color(0xFF173D42),
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
        surfaceTintColor: Colors.transparent,
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          side: const BorderSide(color: Color(0xB3FFFFFF)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          backgroundColor: teal,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    ),
    builder: (context, child) => DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE1F3F2), Color(0xFFF4F7FC), Color(0xFFDCE9F5)],
        ),
      ),
      child: child!,
    ),
    home: const AuthScreen(),
  );
}

class BookingHome extends StatefulWidget {
  const BookingHome({
    super.key,
    this.httpClient,
    this.sessionToken,
    this.onSignOut,
    this.membership,
  });
  final Future<String> Function()? sessionToken;
  final VoidCallback? onSignOut;
  final Map<String, dynamic>? membership;
  final http.Client? httpClient;
  @override
  State<BookingHome> createState() => _BookingHomeState();
}

class _BookingHomeState extends State<BookingHome> {
  final url = TextEditingController(
    text: const String.fromEnvironment(
      'API_URL',
      defaultValue: 'http://127.0.0.1:8000',
    ),
  );
  final token = TextEditingController();
  final scroll = ScrollController();
  late final client = widget.httpClient ?? http.Client();
  List<Map<String, dynamic>> resources = [], bookings = [];
  Map<String, dynamic>? selected;
  DateTime date = DateTime.now().add(const Duration(days: 1));
  String unit = 'hourly';
  int start = 600, tab = 0, offset = 0;
  double duration = 1;
  bool busy = false, connected = false, more = false;
  String? error, notice, retryKey;
  Map<String, dynamic>? retryBody;

  @override
  void initState() {
    super.initState();
    if (widget.sessionToken != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => connect());
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    url.dispose();
    token.dispose();
    client.close();
    super.dispose();
  }

  Future<dynamic> api(
    String path, {
    Map<String, dynamic>? body,
    String? key,
  }) async {
    final base = url.text.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(base);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw Exception(
        'Enter a valid server address, such as http://192.168.1.10:8000.',
      );
    }
    final headers = {
      'Authorization':
          'Bearer ${widget.sessionToken != null ? await widget.sessionToken!() : token.text.trim()}',
      'Content-Type': 'application/json',
      'Idempotency-Key': ?key,
    };
    final response =
        await (body == null
                ? client.get(Uri.parse('$base$path'), headers: headers)
                : client.post(
                    Uri.parse('$base$path'),
                    headers: headers,
                    body: jsonEncode(body),
                  ))
            .timeout(const Duration(seconds: 20));
    final data = jsonDecode(response.body);
    if (response.statusCode >= 400) {
      if (response.statusCode == 401) {
        throw Exception(
          widget.sessionToken != null
              ? 'Your session has expired. Please sign out and sign in again.'
              : 'Your token is missing or expired. Open Connection and paste a fresh token.',
        );
      }
      final detail = data['detail'];
      throw Exception(
        detail is List ? detail.map((e) => e['msg']).join('\n') : '$detail',
      );
    }
    return data;
  }

  Future<void> perform(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is TimeoutException
              ? retryBody != null
                    ? 'The server did not respond in time. Your booking may have been saved. Check My bookings or retry confirmation safely.'
                    : 'The booking server did not respond in time. Check your connection and make sure the server is running, then try again.'
              : e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (scroll.hasClients) scroll.jumpTo(0);
      }
    }
  }

  Future<void> connect() => perform(() async {
    final data = await api('/v1/resources');
    if (!mounted) return;
    setState(() {
      resources = List<Map<String, dynamic>>.from(data);
      connected = true;
      selected = resources.isEmpty ? null : resources.first;
      unit = selected?['preferred_unit'] ?? 'hourly';
      duration = 1;
      retryKey = null;
      retryBody = null;
      notice = resources.isEmpty ? 'No facilities are available yet.' : null;
    });
  });
  Future<void> loadBookings({bool append = false}) => perform(() async {
    final next = append ? offset + 20 : 0;
    final data = List<Map<String, dynamic>>.from(
      await api('/v1/bookings?limit=20&offset=$next'),
    );
    if (mounted) {
      setState(() {
        bookings = append ? [...bookings, ...data] : data;
        offset = next;
        more = data.length == 20;
      });
    }
  });
  Map<String, dynamic> payload() => {
    'resource_id': selected!['id'],
    'date': day(date),
    'duration_unit': unit,
    'duration': duration,
    if (unit == 'hourly') 'start_time': clock(start),
  };
  String newKey() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  Future<void> check() => perform(() async {
    final body = payload();
    final availability = await api('/v1/availability', body: body);
    if (!mounted) return;
    if (availability['available'] != true) {
      setState(
        () =>
            error = 'This time is already booked. Please choose another time.',
      );
      return;
    }
    retryBody = Map.of(body);
    retryKey = newKey();
    await submit();
  });
  Future<void> submit() async {
    final result = await api('/v1/bookings', body: retryBody!, key: retryKey!);
    retryKey = null;
    retryBody = null;
    if (mounted) {
      setState(
        () => notice = result['status'] == 'cancelled'
            ? 'This booking was cancelled.'
            : 'You’re booked! View your reservation in My bookings.',
      );
    }
    if (mounted) {
      setState(() => tab = 2);
      await loadBookings();
    }
  }

  Future<void> cancel(Map<String, dynamic> booking) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this booking?'),
        content: const Text(
          'The reserved time will become available to other members.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep booking'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel booking'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await perform(() async {
      final updated = await api(
        '/v1/bookings/${booking['id']}/cancel',
        body: {},
      );
      if (mounted) {
        setState(() {
          final index = bookings.indexWhere((b) => b['id'] == booking['id']);
          bookings[index] = Map<String, dynamic>.from(updated);
          notice = 'Booking cancelled.';
        });
      }
    });
  }

  Widget gap() => const SizedBox(height: 12);
  Widget message(String text, bool warning) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: warning ? const Color(0xFFFFEAE7) : const Color(0xFFE0F1EB),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Text(text, style: TextStyle(color: warning ? Colors.brown : teal)),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Elite Health Club'),
      backgroundColor: const Color(0xBFFFFFFF),
    ),
    bottomNavigationBar: connected
        ? GlassSurface(child: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: busy
                ? null
                : (value) {
                    setState(() {
                      tab = value;
                      error = null;
                      notice = null;
                    });
                    if (scroll.hasClients) scroll.jumpTo(0);
                    if (value == 2) loadBookings();
                  },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.calendar_month_outlined),
                label: 'Bookings',
              ),
              NavigationDestination(
                icon: Icon(Icons.event_available_outlined),
                label: 'My bookings',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                label: 'Profile',
              ),
            ],
          ))
        : null,
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(16),
            children: [
              if (busy) const LinearProgressIndicator(),
              if (error != null) message(error!, true),
              if (notice != null) message(notice!, false),
              if (!connected)
                ...(widget.sessionToken == null
                    ? connection()
                    : [
                        const SizedBox(height: 48),
                        const Text(
                          'Your club awaits.',
                          style: TextStyle(fontSize: 28),
                        ),
                        gap(),
                        const Text(
                          'Choose a facility and make time for yourself.',
                        ),
                        gap(),
                        FilledButton(
                          onPressed: busy ? null : connect,
                          child: const Text('Load facilities'),
                        ),
                      ])
              else if (tab == 0)
                ...homepage()
              else if (tab == 1)
                ...form()
              else if (tab == 2)
                ...history()
              else
                ...profile(),
            ],
          ),
        ),
      ),
    ),
  );
  List<Widget> homepage() => [
    const SizedBox(height: 8),
    Text(
      'Good morning,\nMember',
      style: Theme.of(context).textTheme.headlineLarge,
    ),
    const SizedBox(height: 10),
    const Text(
      'HEALTHIER PEOPLE · BRIGHTER DAYS',
      style: TextStyle(
        color: Color(0xFF9A8051),
        letterSpacing: 2,
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
    ),
    const SizedBox(height: 24),
    const BookingIntro(),
    const SizedBox(height: 24),
    Row(
      children: [
        Expanded(
          child: Text(
            'Book a facility',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        IconButton(
          onPressed: () => setState(() => tab = 1),
          icon: const Icon(Icons.arrow_forward, color: teal),
        ),
      ],
    ),
    const SizedBox(height: 8),
    GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.65,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      children: resources
          .map(
            (r) => Material(
              color: const Color(0xFFF0EBDD),
              borderRadius: BorderRadius.circular(24),
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: busy || retryKey != null
                    ? null
                    : () => setState(() {
                        selected = r;
                        unit = r['preferred_unit'];
                        duration = 1;
                        tab = 1;
                      }),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(facilityIcon(r['name']), color: teal, size: 28),
                      const SizedBox(height: 8),
                      Flexible(
                        child: Text(
                          r['name'],
                          style: const TextStyle(
                            fontFamily: '.SF Pro Display',
                            fontSize: 16,
                            color: teal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
          .toList(),
    ),
    const SizedBox(height: 24),
    Card(
      child: ListTile(
        leading: const Icon(Icons.event_available_outlined, color: teal),
        title: const Text('Your bookings'),
        subtitle: const Text('Make more time for yourself'),
        trailing: const Icon(Icons.chevron_right),
        onTap: busy
            ? null
            : () {
                setState(() => tab = 2);
                loadBookings();
              },
      ),
    ),
    if (resources.isEmpty)
      const Text('Facilities will appear here when available.'),
  ];

  List<Widget> profile() => [
    Text(
      'Profile & settings',
      style: Theme.of(context).textTheme.headlineLarge
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 24),
    const CircleAvatar(radius: 36, child: Icon(Icons.person_outline, size: 40)),
    gap(),
    Center(
      child: Text(
        widget.membership?['username']?.toString() ?? 'Club member',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
    ),
    const SizedBox(height: 24),
    if (widget.membership?['access_status'] != null)
      Card(
        child: ListTile(
          leading: const Icon(Icons.card_membership_outlined, color: teal),
          title: const Text('Membership'),
          subtitle: Text(
            widget.membership!['access_status'].toString().replaceAll('_', ' '),
          ),
        ),
      ),
    Card(
      child: ListTile(
        leading: const Icon(Icons.workspace_premium_outlined, color: teal),
        title: const Text('Membership type'),
        subtitle: Text(widget.membership?['user_type']?.toString().replaceAll('_', ' ') ?? 'Not assigned'),
      ),
    ),
    for (final purchase in (widget.membership?['purchases'] as List? ?? []))
      Card(child: ListTile(
        leading: const Icon(Icons.event_outlined, color: teal),
        title: Text(purchase['plan'].toString()),
        subtitle: Text('Valid until: ${purchase['valid_until'] ?? 'Not available'}'),
      )),
    const Card(
      child: ListTile(
        leading: Icon(Icons.schedule_outlined, color: teal),
        title: Text('Club time zone'),
        subtitle: Text('India Standard Time (IST)'),
      ),
    ),
    const Card(
      child: ListTile(
        leading: Icon(Icons.info_outline, color: teal),
        title: Text('Elite Health Club'),
        subtitle: Text('Your club. Your time.'),
      ),
    ),
    const SizedBox(height: 24),
    if (widget.onSignOut != null)
      OutlinedButton.icon(
        onPressed: busy ? null : widget.onSignOut,
        icon: const Icon(Icons.logout),
        label: const Text('Sign out'),
      ),
    if (widget.sessionToken == null)
      OutlinedButton(
        onPressed: busy ? null : () => setState(() => connected = false),
        child: const Text('Connection settings'),
      ),
  ];

  Future<void> reschedule(Map<String, dynamic> booking) async {
    final original = DateTime.parse(booking['starts_at'])
        .toUtc()
        .add(const Duration(hours: 5, minutes: 30));
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: original,
      firstDate: DateTime(today.year, today.month, today.day),
      lastDate: today.add(const Duration(days: 365)),
    );
    if (picked == null || !mounted) return;
    TimeOfDay? time;
    if (booking['duration_unit'] == 'hourly') {
      time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: original.hour, minute: original.minute),
      );
      if (time == null || !mounted) return;
      if (time.minute != 0 && time.minute != 30) {
        setState(() => error = 'Choose a start time on the hour or half hour.');
        return;
      }
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reschedule booking?'),
        content: Text(
          'Move to ${day(picked)}'
          '${time == null ? '' : ' · ${clock(time.hour * 60 + time.minute)}'} IST. Your duration stays the same.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep booking'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reschedule'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await perform(() async {
      final updated = await api(
        '/v1/bookings/${booking['id']}/reschedule',
        body: {
          'resource_id': booking['resource_id'],
          'date': day(picked),
          'duration_unit': booking['duration_unit'],
          'duration': booking['duration'],
          if (time != null) 'start_time': clock(time.hour * 60 + time.minute),
        },
      );
      if (!mounted) return;
      setState(() {
        final index = bookings.indexWhere((b) => b['id'] == booking['id']);
        bookings[index] = Map<String, dynamic>.from(updated);
        notice = 'Booking rescheduled.';
      });
    });
  }

  List<Widget> connection() => [
    Center(child: Image.asset('assets/logo.png', height: 150)),
    gap(),
    Text(
      'Your club. Your time.',
      style: Theme.of(context).textTheme.headlineMedium
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
    gap(),
    const Text('Book a court, make time to unwind, or plan your next stay.'),
    gap(),
    const Text(
      'Connect to your club',
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
    ),
    gap(),
    TextField(
      controller: url,
      enabled: !busy,
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'Server address',
        hintText: 'http://192.168.1.10:8000',
      ),
    ),
    gap(),
    TextField(
      controller: token,
      enabled: !busy,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(labelText: 'Member access token'),
    ),
    gap(),
    const Text(
      'For local testing, use the temporary token generated by your booking server. Your token is kept only for this app session.',
      style: TextStyle(color: Colors.black54),
    ),
    gap(),
    FilledButton(
      onPressed: busy ? null : connect,
      child: Text(busy ? 'Connecting…' : 'Connect'),
    ),
  ];
  List<Widget> form() {
    if (selected == null) {
      return [
        const Text('No facilities available.'),
        TextButton(
          onPressed: busy ? null : connect,
          child: const Text('Refresh'),
        ),
      ];
    }
    return [
      const BookingIntro(),
      const SizedBox(height: 24),
      BookingSection(
        number: '01',
        title: 'Find your space',
        subtitle: '${resources.length} facilities · Swipe to explore your club',
        child: FacilityCards(
          resources: resources,
          selectedId: selected!['id'],
          onSelected: busy || retryKey != null
              ? null
              : (resource) => setState(() {
                  selected = resource;
                  unit = resource['preferred_unit'];
                  duration = 1;
                }),
        ),
      ),
      const SizedBox(height: 16),
      BookingSection(
        number: '02',
        title: 'Make it a date',
        subtitle: 'Plan a moment that works for you.',
        child: BookingDates(
          selected: date,
          onSelected: busy || retryKey != null
              ? null
              : (value) => setState(() => date = value),
          onCalendar: busy || retryKey != null
              ? null
              : () async {
                  final today = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: date,
                    firstDate: DateTime(today.year, today.month, today.day),
                    lastDate: today.add(const Duration(days: 365)),
                  );
                  if (picked != null && mounted) setState(() => date = picked);
                },
        ),
      ),
      const SizedBox(height: 16),
      if ((selected!['allowed_units'] as List).length > 1) ...[
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'hourly', label: Text('By the hour')),
            ButtonSegment(value: 'daily', label: Text('By the day')),
          ],
          selected: {unit},
          onSelectionChanged: busy || retryKey != null
              ? null
              : (v) => setState(() {
                  unit = v.first;
                  duration = 1;
                }),
        ),
        gap(),
      ],
      durationControl(),
      if (unit == 'hourly') ...[
        gap(),
        SlotPicker(
          key: ValueKey('${selected!['id']}-${day(date)}-$unit-$duration'),
          selected: start,
          locked: busy || retryKey != null,
          onSelected: (value) => setState(() => start = value),
          load: () => api('/v1/availability/slots', body: payload()),
        ),
      ],
      gap(),
      Text(
        'Times are in ${selected!['timezone']}.${unit == 'daily' ? ' Day bookings run from midnight to midnight.' : ' Start times are in 30-minute intervals.'}',
        style: const TextStyle(color: Colors.black54),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF2EE),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(facilityIcon(selected!['name']), color: teal),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selected!['name'],
                    style: const TextStyle(
                      color: bookingInk,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${friendlyDate(date)} · ${unit == 'hourly' ? clock(start) : 'Full day'} · ${durationLabel(duration, unit)}',
                    style: const TextStyle(
                      color: Color(0xFF687C7D),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      if (retryKey != null) ...[
        const Text(
          'The last confirmation could not be completed. Retry safely with the same booking details.',
        ),
        gap(),
        FilledButton(
          onPressed: busy ? null : () => perform(submit),
          child: const Text('Retry confirmation'),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () async {
                  await loadBookings();
                  if (mounted) setState(() => tab = 2);
                },
          child: const Text('Check My bookings'),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () => setState(() {
                  retryKey = null;
                  retryBody = null;
                  error = null;
                }),
          child: const Text('Change selection (check bookings first)'),
        ),
      ] else
        FilledButton.icon(
          onPressed: busy ? null : check,
          icon: const Icon(Icons.arrow_forward),
          label: Text(busy ? 'Please wait…' : 'Confirm booking'),
        ),
      const SizedBox(height: 12),
      const Text(
        'Check your details above. Confirm booking reserves your time immediately.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, height: 1.5, color: Color(0xFF687C7D)),
      ),
      const SizedBox(height: 20),
    ];
  }

  String durationLabel(double value, String bookingUnit) {
    final number = value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
    final label = bookingUnit == 'hourly' ? 'hour' : 'day';
    return '$number $label${value == 1 ? '' : 's'}';
  }

  Widget durationControl() {
    final step = unit == 'hourly' ? 0.5 : 1.0;
    final maximum =
        (selected![unit == 'hourly'
                    ? 'max_hourly_duration'
                    : 'max_daily_duration']
                as num)
            .toDouble();
    final locked = busy || retryKey != null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xB3FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Duration', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton.outlined(
                tooltip: 'Decrease duration',
                onPressed: locked || duration <= step
                    ? null
                    : () =>
                          setState(() => duration = max(step, duration - step)),
                icon: const Icon(Icons.remove),
              ),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    durationLabel(duration, unit),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: teal,
                    ),
                  ),
                ),
              ),
              IconButton.outlined(
                tooltip: 'Increase duration',
                onPressed: locked || duration >= maximum
                    ? null
                    : () => setState(
                        () => duration = min(maximum, duration + step),
                      ),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${unit == 'hourly' ? '30-minute' : '1-day'} increments · Up to ${durationLabel(maximum, unit)}',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget bookingDetail(IconData icon, String label, String value) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 16, color: teal),
      const SizedBox(width: 7),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
            Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ],
  );

  List<Widget> history() => [
    Row(
      children: [
        Expanded(
          child: Text(
            'My bookings',
            style: Theme.of(context).textTheme.headlineLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        IconButton.outlined(
          tooltip: 'Refresh bookings',
          onPressed: busy ? null : loadBookings,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    const SizedBox(height: 8),
    Text(
      'Your reservations · All times in IST',
      style: const TextStyle(fontSize: 12, color: Colors.black54),
    ),
    gap(),
    if (bookings.isEmpty && !busy)
      Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            const Icon(Icons.event_available_outlined, size: 48, color: teal),
            const SizedBox(height: 16),
            const Text(
              'Your next visit starts here',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Book a facility and find all your reservation details here.',
              textAlign: TextAlign.center,
            ),
            gap(),
            FilledButton(
              onPressed: () => setState(() => tab = 1),
              child: const Text('Book a facility'),
            ),
          ],
        ),
      ),
    ...bookings.map((b) {
      final matching = resources.where((r) => r['id'] == b['resource_id']);
      final confirmed = b['status'] == 'confirmed';
      final begins = DateTime.parse(b['starts_at']);
      final ends = DateTime.parse(b['ends_at']);
      final upcoming = begins.isAfter(DateTime.now());
      final completed = confirmed && !ends.isAfter(DateTime.now());
      final label = !confirmed
          ? 'Cancelled'
          : completed
          ? 'Completed'
          : upcoming
          ? 'Confirmed'
          : 'In progress';
      final hours = ends.difference(begins).inMinutes / 60;
      final elapsed = hours >= 24 && hours % 24 == 0
          ? durationLabel(hours / 24, 'daily')
          : durationLabel(hours, 'hourly');
      final statusColor = !confirmed
          ? const Color(0xFF9B493D)
          : completed
          ? const Color(0xFF647575)
          : teal;
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xB3FFFFFF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF4F2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.event_note_outlined,
                    size: 20,
                    color: teal,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    matching.isEmpty ? 'Club facility' : matching.first['name'],
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F6F8),
                borderRadius: BorderRadius.circular(10),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final details = [
                    bookingDetail(
                      Icons.calendar_today_outlined,
                      'Starts',
                      clubTime(b['starts_at']),
                    ),
                    bookingDetail(
                      Icons.event_available_outlined,
                      'Ends',
                      clubTime(b['ends_at']),
                    ),
                  ];
                  if (constraints.maxWidth < 290 ||
                      MediaQuery.textScalerOf(context).scale(1) > 1.3) {
                    return Column(
                      children: [
                        details[0],
                        const SizedBox(height: 8),
                        details[1],
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: details[0]),
                      const SizedBox(width: 10),
                      Expanded(child: details[1]),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Icon(Icons.schedule_outlined, size: 14, color: teal),
                Text(
                  elapsed,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (confirmed && upcoming)
                  TextButton.icon(
                    onPressed: busy ? null : () => reschedule(b),
                    icon: const Icon(Icons.edit_calendar_outlined, size: 16),
                    label: const Text('Reschedule'),
                  ),
                if (confirmed && upcoming)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 44),
                    ),
                    onPressed: busy ? null : () => cancel(b),
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text(
                      'Cancel booking',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
    }),
    if (more)
      OutlinedButton(
        onPressed: busy ? null : () => loadBookings(append: true),
        child: const Text('Load more'),
      ),
  ];
}

/// Frosted surface with a bright rim and a soft, tinted shadow.
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(28),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xDDFFFFFF), Color(0x88FFFFFF)],
          ),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xDDFFFFFF)),
        ),
        child: child,
      ),
    ),
  );
}
