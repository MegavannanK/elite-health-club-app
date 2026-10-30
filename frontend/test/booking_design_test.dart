import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:elite_health_club/main.dart';
import 'package:elite_health_club/booking_design.dart';
import 'package:elite_health_club/slot_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final width in [320.0, 390.0, 800.0]) {
    testWidgets('Bookings layout and facility selection at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        if (request.url.path == '/v1/resources') {
          return http.Response(
            jsonEncode([
              {
                'id': 'pool',
                'name': 'Swimming Pool',
                'preferred_unit': 'hourly',
                'allowed_units': ['hourly'],
                'timezone': 'Asia/Kolkata',
                'max_hourly_duration': 24,
              },
              {
                'id': 'suite',
                'name': 'Suite 1',
                'preferred_unit': 'daily',
                'allowed_units': ['daily'],
                'timezone': 'Asia/Kolkata',
                'max_daily_duration': 30,
              },
            ]),
            200,
          );
        }
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'slots': List.generate(
              48,
              (index) => {
                'minute': index * 30,
                'status': index == 20 ? 'Booked' : 'Available',
              },
            ),
          }),
          200,
        );
      });
      if (Platform.environment['BOOKING_SCREENSHOTS'] == '1') {
        await tester.runAsync(() async {
          final font = FontLoader('PreviewFont');
          font.addFont(
            Future.value(
              ByteData.sublistView(
                await File('/System/Library/Fonts/Supplemental/Arial.ttf')
                    .readAsBytes(),
              ),
            ),
          );
          await font.load();
          final icons = FontLoader('MaterialIcons');
          icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
          await icons.load();
        });
      }
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: Platform.environment['BOOKING_SCREENSHOTS'] == '1'
                  ? 'PreviewFont'
                  : null,
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(seedColor: teal),
              scaffoldBackgroundColor: const Color(0xFFF6F8F7),
            ),
            debugShowCheckedModeBanner: false,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(width == 320 ? 1.3 : 1)),
              child: child!,
            ),
            home: BookingHome(
              httpClient: client,
              sessionToken: () async => 'session',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bookings'));
      await tester.pumpAndSettle();
      expect(find.text('Find your space'), findsOneWidget);
      expect(tester.takeException(), isNull);
      Future<void> screenshot(String name) async {
        if (width != 390 || Platform.environment['BOOKING_SCREENSHOTS'] != '1') {
          return;
        }
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/private/tmp/$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await screenshot('bookings-preview');
      final scrollable = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(find.byType(BookingDates), 180, scrollable: scrollable);
      await tester.pumpAndSettle();
      final dates = tester.widget<BookingDates>(find.byType(BookingDates));
      final today = DateUtils.dateOnly(DateTime.now());
      final dateList = find.descendant(of: find.byType(BookingDates), matching: find.byType(ListView));
      final firstDate = find.descendant(of: dateList, matching: find.byType(InkWell)).first;
      await tester.ensureVisible(firstDate);
      await tester.pumpAndSettle();
      await tester.tap(firstDate);
      await tester.pumpAndSettle();
      expect(
        DateUtils.isSameDay(
          tester.widget<BookingDates>(find.byType(BookingDates)).selected,
          today,
        ),
        isTrue,
      );
      expect(DateUtils.isSameDay(dates.selected, today), isFalse);
      await tester.scrollUntilVisible(
        find.byType(SlotPicker),
        250,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(requests.last['resource_id'], 'pool');
      expect(requests.last['date'], day(today));
      await tester.ensureVisible(find.text('11:00'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('11:00'));
      await tester.pumpAndSettle();
      expect(tester.widget<SlotPicker>(find.byType(SlotPicker)).selected, 660);
      final booked = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('10:00'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(booked.onPressed, isNull);
      await tester.scrollUntilVisible(
        find.text('Choose your time'),
        -180,
        scrollable: scrollable,
      );
      await tester.ensureVisible(find.text('Afternoon'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Afternoon'));
      await tester.pumpAndSettle();
      expect(find.text('12:00'), findsOneWidget);
      expect(find.text('Selected start: 11:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await screenshot('bookings-times-preview');
      await tester.scrollUntilVisible(
        find.text('Find your space'),
        -250,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Suite 1').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Suite 1').first);
      await tester.pumpAndSettle();
      expect(find.byType(SlotPicker), findsNothing);
      await tester.scrollUntilVisible(
        find.text('1 day'),
        200,
        scrollable: scrollable,
      );
      expect(find.text('1 day'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
