# ScrollLock

ScrollLock is an iOS Screen Time app for setting per-app daily, hourly, per-session, and schedule-based limits. It uses Apple's Family Controls, Device Activity, Managed Settings, and App Intents frameworks. Usage records stay on the device in an App Group shared by the app and its extensions.

## Requirements

- macOS with Xcode
- iOS 17.4 or later
- Apple Developer account with the Family Controls capability for device installation

## Configure a personal build

1. Open `ScrollLock.xcodeproj` in Xcode and select the ScrollLock scheme.
2. Set a unique bundle identifier for the app and each extension, then set your development team in Signing & Capabilities.
3. Create an App Group for your account. Replace `group.com.example.scrolllock` with that identifier in all four `.entitlements` files, `ScrollLock/ScrollLockData.swift`, and `Shared/ScrollLockState.swift`.
4. Enable the matching Family Controls and App Groups capabilities for the app and extensions in your Apple Developer account.
5. Build and install on a compatible device, then grant Screen Time access in the app.

The project uses example identifiers. They are placeholders and will not work with your Apple account as-is.

## How it works

- Choose individual apps and set daily, hourly, per-session, and schedule limits.
- Settings save automatically, with validation and visible save failures.
- Per-session limits use personal Shortcuts automations for app-open and app-close events.
- Screen Time monitoring and selected-app records stay on device. The app does not send usage history to a server.
- There is no in-app control that clears restrictions.

See [PRIVACY.md](PRIVACY.md) for the data handling summary.

## Project status

This is an independent project using Apple's Screen Time APIs. Physical-device behavior can vary with iOS scheduling and Shortcuts delivery. Review the source and verify the behaviors you rely on before using it to enforce limits.
