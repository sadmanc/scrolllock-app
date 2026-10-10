# Privacy

ScrollLock has no account, advertising, analytics SDK, or developer-operated server. It does not upload Screen Time usage history.

## On-device data

To enforce limits, ScrollLock stores selected-app tokens and display names, limit and schedule settings, timing state, and the status history shown in the app. These records live in an iOS-protected App Group container shared by the app and its Screen Time extensions.

The Analytics screen asks Apple's Device Activity API for usage totals, pickups, and notification counts for apps selected in ScrollLock. It displays that report on the device. The app does not save the full report or send it to a server.

ScrollLock does not request a name, email, contacts, location, photos, camera, or microphone. Screen Time access is requested only after the user grants it. Shortcuts automations run through Apple's Shortcuts app.

Development builds may retain a limited local trace of selected app identifiers, names, and enforcement events for debugging. Release builds omit that trace. Apple handles its Screen Time services and any device backups under the user's iOS settings and Apple's privacy terms.
