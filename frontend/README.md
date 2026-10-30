# Elite Health Club — Flutter booking app

Simple member booking app using the existing FastAPI backend. Your supplied logo is used in the welcome screen and iOS/Android/web icons.

Features: live facility catalog, supported hourly/daily durations, 30-minute start times, availability check, confirmation, safe retry using the original idempotency key/body, paginated booking history, and cancellation. The API is the final authority on conflicts and booking rules. Booking history displays India time (IST); the booking form shows the resource timezone.

## Run with the connected development instance

```sh
sh tool/dev.sh
```

Open http://localhost:3000. This uses the existing Clerk development instance and the local backend at http://localhost:8000. Start the backend as described below first. The PWA uses Clerk’s browser session; iOS and Android use Clerk’s Flutter SDK. `config/dev.json` contains only the public publishable key; the Clerk secret remains in the backend environment.

For a physical phone, use your Mac’s LAN address for the backend:

```sh
sh tool/dev.sh -d YOUR_IPHONE_DEVICE_ID --dart-define=API_URL=http://YOUR_MAC_IP:8000
```

## Member login and signup

The app opens Clerk sign-in, signup, and verification, then calls `POST /auth/login` or `POST /auth/signup` with the session token to synchronize membership. After authentication and profile synchronization, users enter the booking app and can view or cancel their bookings. The backend enforces paid membership rules when creating a booking. Booking requests automatically retrieve a current token.

```sh
flutter run --dart-define=CLERK_PUBLISHABLE_KEY=pk_test_YOUR_KEY --dart-define=API_URL=http://YOUR_MAC_IP:8000
```

Use your public publishable key, never a secret key. Configure the same Clerk instance in the backend. Web requires matching Clerk authorized parties and backend CORS origins. Sign-in methods follow your Clerk dashboard configuration. Without a key the app displays a setup message. Live authentication requires your Clerk account and running backend.

The token connection instructions below apply to direct BookingHome development tests; the main app uses Clerk.

## Test on your iPhone

### 1. Start the backend on your Mac

Keep your Mac and iPhone on the same trusted Wi-Fi. Open a terminal:

```sh
cd /Users/megavannank/Desktop/projects/app/elitehealthclub/backend
source ../.venv/bin/activate
docker compose up -d db --wait
python -m app.manage migrate
python -m app.manage seed
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Leave it running. Allow incoming connections if macOS asks. Binding to 0.0.0.0 makes the development API reachable from your local network; use this only on a trusted network.

Find your Mac's Wi-Fi IP in **System Settings → Wi-Fi → Details → TCP/IP** (for example 192.168.1.10). On the iPhone, open `http://192.168.1.10:8000/health/ready` in Safari, replacing that example with your Mac's address. Expect `{"status":"ready"}`. Do not use localhost or 127.0.0.1 on the iPhone: those refer to the phone itself.

In another terminal, generate a token:

```sh
cd /Users/megavannank/Desktop/projects/app/elitehealthclub/backend
source ../.venv/bin/activate
python -m app.manage token --user demo-member
```

Copy the token privately to your phone. It expires after one hour; generate another when needed.

### 2. Prepare the iPhone and Xcode (first time)

1. Connect the unlocked iPhone to your Mac with a cable. Accept **Trust This Computer**.
2. On iPhone, enable **Settings → Privacy & Security → Developer Mode**, restart, and confirm. If unavailable, pair it in Xcode first.
3. Open `frontend/ios/Runner.xcworkspace` in Xcode. Select the **Runner** target → **Signing & Capabilities**. Enable automatic signing and select your Apple ID's development team. Add your Apple ID in Xcode Settings if necessary. A personal developer account can be used for local testing.
4. Select your iPhone as the destination. If Xcode asks for iOS platform support, install it. If requested, trust the developer certificate under iPhone **Settings → General → VPN & Device Management**.

Official setup guide: https://docs.flutter.dev/platform-integration/ios/setup

### 3. Run the app

```sh
cd /Users/megavannank/Desktop/projects/app/elitehealthclub/frontend
flutter pub get
flutter devices
flutter run -d YOUR_IPHONE_DEVICE_ID
```

Replace YOUR_IPHONE_DEVICE_ID with the identifier printed by `flutter devices`. Keep the phone unlocked during the first install. Allow **Local Network** access if prompted.

In the app, enter your Mac's server address (for example `http://192.168.1.10:8000`) and paste the token without `Bearer`. Tap **Connect**, select a facility/date/duration, check availability, then confirm. **My bookings** shows the reservation and lets you cancel a future booking.

You may also prefill the server address:

```sh
flutter run -d YOUR_IPHONE_DEVICE_ID --dart-define=API_URL=http://192.168.1.10:8000
```

If an iOS version rejects local numeric HTTP addresses, use the Mac's `.local` hostname from System Settings → General → Sharing (for example `http://Your-Mac.local:8000`). The iOS app allows local networking; production servers should use HTTPS. Android debug builds allow local HTTP; release builds require HTTPS.

## Checks and builds

```sh
flutter analyze
flutter test
flutter build ios --debug --no-codesign
flutter build web
```

An unsigned iOS build verifies compilation but cannot be installed directly on an iPhone. `flutter run` with Xcode signing installs the development build. Android and web projects are included; web use also needs the frontend origin in the backend's CORS_ORIGINS setting.

Tests cover daily request shape, confirmation retry identity, and expired token feedback using a mocked API. Physical-device and live backend end-to-end testing remain separate checks.

If a confirmation request fails, use **Retry confirmation** while keeping the app open. This reuses the same key and booking details. Check **My bookings** before changing the selection or restarting after an uncertain result: the server may already have accepted it.

## Logo updates

Replace `assets/logo.png`, then run:

```sh
dart run flutter_launcher_icons
```
