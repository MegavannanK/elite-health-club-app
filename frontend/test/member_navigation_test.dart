import 'dart:convert';

import 'package:elite_health_club/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('Home, simple reservations and profile navigation', (
    tester,
  ) async {
    var signedOut = false;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/resources') {
        return http.Response(
          jsonEncode([
            {
              'id': 'tennis',
              'name': 'Tennis',
              'preferred_unit': 'hourly',
              'allowed_units': ['hourly'],
              'timezone': 'Asia/Kolkata',
              'max_hourly_duration': 24,
            },
          ]),
          200,
        );
      }
      return http.Response(
        jsonEncode([
          {
            'id': 'private-reference',
            'resource_id': 'tennis',
            'starts_at': DateTime.now()
                .toUtc()
                .add(const Duration(days: 2))
                .toIso8601String(),
            'ends_at': DateTime.now()
                .toUtc()
                .add(const Duration(days: 2, hours: 1))
                .toIso8601String(),
            'status': 'confirmed',
            'duration_unit': 'hourly',
            'duration': 1,
          },
        ]),
        200,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: BookingHome(
          httpClient: client,
          sessionToken: () async => 'session',
          membership: const {'access_status': 'active'},
          onSignOut: () => signedOut = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Welcome to your club'), findsOneWidget);
    await tester.tap(find.text('My bookings'));
    await tester.pumpAndSettle();
    expect(find.text('Tennis'), findsOneWidget);
    expect(find.text('private-reference'), findsNothing);
    expect(find.text('REF  '), findsNothing);
    expect(find.text('Reschedule'), findsOneWidget);
    expect(find.text('Cancel booking'), findsOneWidget);
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Profile & settings'), findsOneWidget);
    expect(find.text('active'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Sign out'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Sign out'));
    expect(signedOut, isTrue);
  });
}
