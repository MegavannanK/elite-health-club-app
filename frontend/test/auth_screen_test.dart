import 'package:elite_health_club/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [375.0, 1200.0]) {
    testWidgets('Member entry fits a $width wide screen', (tester) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ClubApp());
      await tester.pumpAndSettle();
      expect(find.text('Your club. Your space.'), findsOneWidget);
      expect(find.text('A little setup, then you’re in.'), findsOneWidget);
      expect(find.text('Member access token'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
