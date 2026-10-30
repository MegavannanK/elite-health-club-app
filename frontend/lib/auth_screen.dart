import 'dart:async';
import 'dart:convert';

import 'package:clerk_flutter/clerk_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'web_auth_stub.dart' if (dart.library.js_interop) 'web_auth.dart';

import 'package:http/http.dart' as http;

import 'main.dart';

/// Clerk owns credentials and verification; the API owns membership access.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool signingUp = false;

  @override
  Widget build(BuildContext context) {
    const configured = String.fromEnvironment('CLERK_PUBLISHABLE_KEY') != '';
    if (!configured) {
      return const AuthLayout(
        child: Column(
          children: [
            Icon(Icons.lock_outline_rounded, size: 32, color: teal),
            SizedBox(height: 20),
            Text(
              'A little setup, then you’re in.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 12),
            Text(
              'Member sign-in will be available once the app is connected to Clerk.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    if (kIsWeb) return const WebAuthScreen();
    return ClerkErrorListener(
      child: ClerkAuthBuilder(
        builder: (context, auth) {
          if (auth.isSigningUp) signingUp = true;
          if (auth.isSigningIn) signingUp = false;
          if (auth.user != null) {
            return MemberSession(
              key: ValueKey(auth.user!.id),
              sessionToken: () async => (await auth.sessionToken()).jwt,
              onSignOut: auth.signOut,
              signingUp: signingUp,
              username: auth.user!.username ?? auth.user!.firstName,
            );
          }
          return const AuthLayout(child: ClerkAuthentication());
        },
      ),
    );
  }
}

class AuthLayout extends StatelessWidget {
  const AuthLayout({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 860;
          final form = Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(wide ? 48 : 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/logo.png', height: 80),
                    const SizedBox(height: 28),
                    const Text(
                      'MAKE TIME FOR YOU',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 2.5,
                        fontWeight: FontWeight.w600,
                        color: teal,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Your club. Your space.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 32,
                        height: 1.2,
                        letterSpacing: -1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Move, unwind, and feel your best.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF667875)),
                    ),
                    const SizedBox(height: 32),
                    child,
                    const SizedBox(height: 32),
                    const Text(
                      'ELITE HEALTH CLUB · MEMBER ACCESS',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.8,
                        color: Color(0xFF667875),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          if (!wide) return form;
          return Row(
            children: [
              Expanded(
                child: Container(
                  margin: const EdgeInsets.all(24),
                  padding: const EdgeInsets.all(48),
                  decoration: BoxDecoration(
                    color: const Color(0xFF006877),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.spa_outlined,
                        color: Color(0xFFC5DFCE),
                        size: 36,
                      ),
                      Spacer(),
                      Text(
                        'A little movement.\nA deeper breath.\nA better everyday.',
                        style: TextStyle(
                          fontSize: 44,
                          height: 1.2,
                          letterSpacing: -1.5,
                          color: Color(0xFFF1F5EA),
                        ),
                      ),
                      SizedBox(height: 24),
                      Text(
                        'Wellness starts with a moment for yourself.',
                        style: TextStyle(color: Color(0xFFC5DFCE), height: 1.6),
                      ),
                      Spacer(),
                      Text(
                        'MOVE  /  REST  /  RECONNECT',
                        style: TextStyle(
                          color: Color(0xFFC5DFCE),
                          letterSpacing: 2,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(child: form),
            ],
          );
        },
      ),
    ),
  );
}

class MemberSession extends StatefulWidget {
  const MemberSession({
    super.key,
    required this.sessionToken,
    required this.onSignOut,
    required this.signingUp,
    this.httpClient,
    this.username,
  });
  final String? username;
  final http.Client? httpClient;
  final Future<String> Function() sessionToken;
  final Future<void> Function() onSignOut;
  final bool signingUp;

  @override
  State<MemberSession> createState() => _MemberSessionState();
}

class _MemberSessionState extends State<MemberSession> {
  bool busy = true;
  String? error;
  bool signInRequired = false;
  Map<String, dynamic>? membership;

  @override
  void initState() {
    super.initState();
    synchronize();
  }

  Future<String> token() => widget.sessionToken();

  Future<void> synchronize() async {
    setState(() {
      busy = true;
      error = null;
      signInRequired = false;
    });
    final client = widget.httpClient ?? http.Client();
    try {
      const base = String.fromEnvironment(
        'API_URL',
        defaultValue: 'http://127.0.0.1:8000',
      );
      final response = await client
          .post(
            Uri.parse(
              '${base.replaceAll(RegExp(r'/+$'), '')}/auth/${widget.signingUp ? 'signup' : 'login'}',
            ),
            headers: {'Authorization': 'Bearer ${await token()}'},
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        signInRequired = response.statusCode == 401;
        if (response.statusCode == 403) {
          final body = jsonDecode(response.body);
          if (body is Map &&
              body['detail'] is Map &&
              body['detail']['code'] == 'session_pending') {
            signInRequired = true;
            throw Exception(
              'Your sign-in has an unfinished step. Sign in again to continue.',
            );
          }
        }
        throw Exception(
          response.statusCode == 401
              ? 'Your session has expired. Please sign in again.'
              : 'We couldn’t complete sign-in. Please try again shortly.',
        );
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (mounted) setState(() => membership = data);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is TimeoutException
              ? 'This is taking longer than expected. Please try again.'
              : e is http.ClientException
              ? 'Unable to reach the club. Check your connection and try again.'
              : e.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (widget.httpClient == null) client.close();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!busy && error == null && membership != null) {
      return BookingHome(
        httpClient: widget.httpClient,
        membership: {...membership!, if (widget.username != null) 'username': widget.username},
        sessionToken: token,
        onSignOut: widget.onSignOut,
      );
    }
    return AuthLayout(
      child: Column(
        children: [
          if (busy) ...[
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 20),
            const Text('Getting your club ready…'),
          ] else ...[
            Icon(
              error != null
                  ? Icons.cloud_off_outlined
                  : Icons.verified_user_outlined,
              color: teal,
              size: 32,
            ),
            const SizedBox(height: 16),
            Text(
              error ?? 'You’re signed in. Your membership needs to be active before you can book.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: signInRequired ? widget.onSignOut : synchronize,
              child: Text(signInRequired ? 'Sign in again' : 'Try again'),
            ),
          ],
          const SizedBox(height: 16),
          TextButton(
            onPressed: widget.onSignOut,
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
