import 'dart:convert';

import 'package:elite_health_club/auth_screen.dart';
import 'package:elite_health_club/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final signup in [false, true]) {
    testWidgets(
      'Verified ${signup ? 'signup' : 'login'} enters booking even without active membership',
      (tester) async {
        final requests = <String>[];
        final client = MockClient((request) async {
          requests.add(request.url.path);
          expect(request.headers['Authorization'], 'Bearer current-session');
          if (request.url.path.startsWith('/auth/')) {
            expect(request.method, 'POST');
            return http.Response(jsonEncode({'access_status': 'review'}), 200);
          }
          expect(request.url.path, '/v1/resources');
          return http.Response('[]', 200);
        });
        await tester.pumpWidget(
          MaterialApp(
            home: MemberSession(
              sessionToken: () async => 'current-session',
              onSignOut: () async {},
              signingUp: signup,
              httpClient: client,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(requests, [
          '/auth/${signup ? 'signup' : 'login'}',
          '/v1/resources',
        ]);
        expect(find.byType(BookingHome), findsOneWidget);
        expect(find.text('My bookings'), findsOneWidget);
        expect(find.text('Member access token'), findsNothing);
      },
    );
  }
  for (final status in [401, 403]) {
    testWidgets('Rejected session $status offers fresh sign-in', (tester) async {
      var signedOut = false;
      final client = MockClient((request) async => http.Response(
        jsonEncode({'detail': {'code': 'session_pending'}}), status));
      await tester.pumpWidget(MaterialApp(home: MemberSession(
        sessionToken: () async => 'session',
        onSignOut: () async { signedOut = true; },
        signingUp: false,
        httpClient: client,
      )));
      await tester.pumpAndSettle();
      expect(find.byType(BookingHome), findsNothing);
      expect(find.text('Try again'), findsNothing);
      await tester.tap(find.text('Sign in again'));
      await tester.pumpAndSettle();
      expect(signedOut, isTrue);
    });
  }

}
