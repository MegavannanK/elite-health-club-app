import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'auth_screen.dart';

@JS('Clerk')
external ClerkBrowser? get browserClerk;

extension type ClerkBrowser(JSObject _) implements JSObject {
  external JSPromise<JSAny?> load(JSObject options);
  external JSObject? get user;
  external ClerkSession? get session;
  external JSFunction addListener(JSFunction listener);
  external void mountSignIn(web.HTMLElement element, JSObject options);
  external void mountSignUp(web.HTMLElement element, JSObject options);
  external void unmountSignIn(web.HTMLElement element);
  external void unmountSignUp(web.HTMLElement element);
  external JSPromise<JSAny?> signOut();
}

extension type ClerkSession(JSObject _) implements JSObject {
  external String get id;
  external JSPromise<JSString?> getToken();
}

/// Use Clerk's browser SDK for cookie sessions, verification, and CAPTCHA.
/// Native builds use the Flutter SDK through AuthScreen instead.
class WebAuthScreen extends StatefulWidget {
  const WebAuthScreen({super.key});
  @override
  State<WebAuthScreen> createState() => _WebAuthScreenState();
}

class _WebAuthScreenState extends State<WebAuthScreen> {
  static Future<ClerkBrowser>? _loading;
  ClerkBrowser? clerk;
  JSFunction? unsubscribe;
  web.HTMLDivElement? container;
  bool signingUp = false;
  bool loading = true;
  String? error;
  int formVersion = 0;

  @override
  void initState() {
    super.initState();
    signingUp = web.window.sessionStorage.getItem('ehc-auth-mode') == 'signup';
    initialize();
  }

  static Future<ClerkBrowser> load() async {
    if (browserClerk == null) {
      const key = String.fromEnvironment('CLERK_PUBLISHABLE_KEY');
      final encoded = key.substring(key.lastIndexOf('_') + 1);
      final domain = utf8
          .decode(base64.decode(base64.normalize(encoded)))
          .split(r'$')
          .first;
      final script = web.HTMLScriptElement()
        ..src = 'https://$domain/npm/@clerk/clerk-js@5/dist/clerk.browser.js'
        ..async = true
        ..crossOrigin = 'anonymous'
        ..setAttribute('data-clerk-publishable-key', key);
      final completer = Completer<void>();
      script.onLoad.first.then((_) {
        if (!completer.isCompleted) completer.complete();
      });
      script.onError.first.then((_) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('Clerk could not load'));
        }
      });
      web.document.head!.appendChild(script);
      try {
        await completer.future.timeout(const Duration(seconds: 25));
      } catch (_) {
        script.remove();
        rethrow;
      }
    }
    final instance = browserClerk!;
    await instance
        .load(
          {
                'appearance': {
                  'variables': {
                    'colorPrimary': '#006877',
                    'colorText': '#173D42',
                    'borderRadius': '14px',
                    'fontFamily': 'Arial, sans-serif',
                  },
                  'elements': {
                    'rootBox': {'width': '100%'},
                    'cardBox': {'width': '100%', 'boxShadow': 'none'},
                    'card': {'boxShadow': 'none'},
                    'footerAction': {'display': 'none'},
                  },
                },
              }.jsify()!
              as JSObject,
        )
        .toDart;
    return instance;
  }

  Future<void> initialize() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final instance = await (_loading ??= load());
      if (!mounted) return;
      clerk = instance;
      unsubscribe = instance.addListener(
        ((JSObject _) {
          if (mounted) setState(() {});
        }).toJS,
      );
      setState(() => loading = false);
    } catch (_) {
      _loading = null;
      if (mounted) {
        setState(() {
          loading = false;
          error =
              'We couldn’t load sign-in. Check your connection and try again.';
        });
      }
    }
  }

  void unmountForm() {
    final element = container;
    if (element == null || clerk == null) return;
    clerk!.unmountSignIn(element);
    clerk!.unmountSignUp(element);
    container = null;
  }

  void switchMode(bool value) {
    unmountForm();
    web.window.sessionStorage.setItem(
      'ehc-auth-mode',
      value ? 'signup' : 'login',
    );
    setState(() {
      signingUp = value;
      formVersion++;
    });
  }

  @override
  void dispose() {
    unsubscribe?.callAsFunction();
    unmountForm();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final instance = clerk;
    final session = instance?.session;
    if (instance != null && instance.user != null && session != null) {
      return MemberSession(
        key: ValueKey(session.id),
        signingUp: signingUp,
        username: ((clerk!.user?.dartify() as Map?)?['username'] ?? (clerk!.user?.dartify() as Map?)?['firstName']) as String?,
        sessionToken: () async {
          final token = await instance.session?.getToken().toDart;
          if (token == null) throw Exception('Please sign in again.');
          return token.toDart;
        },
        onSignOut: () async {
          await instance.signOut().toDart;
        },
      );
    }
    return AuthLayout(
      child: Column(
        children: [
          if (loading) ...[
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 16),
            const Text('Preparing secure sign-in…'),
          ] else if (error != null) ...[
            Text(error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: initialize, child: const Text('Try again')),
          ] else ...[
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Log in')),
                ButtonSegment(value: true, label: Text('Sign up')),
              ],
              selected: {signingUp},
              onSelectionChanged: (values) => switchMode(values.single),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 560,
              child: HtmlElementView.fromTagName(
                key: ValueKey(formVersion),
                tagName: 'div',
                onElementCreated: (object) {
                  final element = object as web.HTMLDivElement;
                  container = element;
                  element.style
                    ..width = '100%'
                    ..height = '100%'
                    ..overflow = 'auto';
                  final options =
                      {
                            'routing': 'hash',
                            'forceRedirectUrl': web.window.location.origin,
                          }.jsify()!
                          as JSObject;
                  if (signingUp) {
                    instance!.mountSignUp(element, options);
                  } else {
                    instance!.mountSignIn(element, options);
                  }
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
