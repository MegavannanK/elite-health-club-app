import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:elite_health_club/main.dart';

void main() {
  testWidgets(
    'Daily bookings omit time and confirmation retries keep the same key',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final creates = <http.Request>[];
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer test-token');
        if (request.url.path == '/v1/resources') {
          return http.Response(
            jsonEncode([
              {
                'id': 'suite-1',
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
        if (request.url.path == '/v1/availability') {
          expect(jsonDecode(request.body).containsKey('start_time'), false);
          expect(jsonDecode(request.body)['duration'], 2);
          return http.Response('{"available":true}', 200);
        }
        creates.add(request);
        if (creates.length == 1) {
          throw TimeoutException('Future not completed');
        }
        return http.Response('{"status":"confirmed"}', 200);
      });
      await tester.pumpWidget(
        MaterialApp(home: BookingHome(httpClient: client)),
      );
      await tester.enterText(find.byType(TextField).last, 'test-token');
      await tester.scrollUntilVisible(
        find.text('Connect'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to your club'), findsOneWidget);
      await tester.tap(find.text('Bookings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Decrease duration'));
      await tester.tap(find.byTooltip('Decrease duration'));
      await tester.pump();
      expect(find.text('1 day'), findsOneWidget);
      await tester.tap(find.byTooltip('Increase duration'));
      await tester.pump();
      expect(find.text('2 days'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Review booking'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Review booking'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Confirm booking'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Your booking may have been saved'),
        findsOneWidget,
      );
      expect(find.textContaining('TimeoutException'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Retry confirmation'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Retry confirmation'));
      await tester.pumpAndSettle();
      expect(creates.length, 2);
      expect(
        creates[0].headers['Idempotency-Key'],
        creates[1].headers['Idempotency-Key'],
      );
      expect(creates[0].body, creates[1].body);
      expect(find.textContaining('You’re booked!'), findsOneWidget);
    },
  );
  testWidgets('Connection timeout gives server guidance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BookingHome(
          httpClient: MockClient((_) async {
            throw TimeoutException('Future not completed');
          }),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Connect'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('make sure the server is running'),
      findsOneWidget,
    );
    expect(find.textContaining('TimeoutException'), findsNothing);
  });
  testWidgets('Expired token feedback', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BookingHome(
          httpClient: MockClient(
            (_) async => http.Response('{"detail":"Unauthorized"}', 401),
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Connect'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('expired'), findsOneWidget);
  });
}
