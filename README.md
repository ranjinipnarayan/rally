# Rally for iOS and Messages

Rally uses the website backend as the source of truth. The iOS app provides
email sign-in and organizer management; the Messages extension creates plans
through a structured black-and-white interface. Recipients open public HTTPS
links and reply on the website without an account or extension.

## Current flow

- Sign in to the app using an email magic link.
- View Needs You, Active, and Past, with backend status, response counts, and next actions.
- Review responses, save final choices, explicitly confirm, cancel, or archive.
- Share the backend's final message and open the confirmed location in Maps.
- In Messages, choose activity, specific/polled time, and specific/open location.
- Save a private draft or create a public Rally, then insert its title and link.
  You tap Send yourself. Saving or creating requires login.

Dashboard data refreshes on foreground entry and manual refresh. No local
lifecycle, contact access, natural-language interpretation, or recommendations
are used. Draft editing can continue in the current Messages composer or on
the website. Unsaved composer state is in memory only.

## Development setup

Keep the existing development identifiers:

| Setting | Value |
| --- | --- |
| App bundle ID | `com.example.RallyMessages` |
| Extension bundle ID | `com.example.RallyMessages.MessagesExtension` |
| Team | `NWUMX9X84W` |
| App Group | `group.com.example.RallyMessages` |
| Keychain group | `$(AppIdentifierPrefix)com.example.RallyMessages.shared` |
| Email callback | `com.example.RallyMessages://auth/callback` |

1. Add the exact callback to Supabase Authentication → URL Configuration →
   Redirect URLs. Retain the existing website redirects. Open the magic link
   on the device that requested it (PKCE).
2. In Xcode, ensure both targets' provisioning profiles support the configured
   App Group and Keychain Sharing entitlements. Xcode resolves AppIdentifierPrefix
   from signing; do not substitute an assumed prefix.
3. Run the RallyMessages scheme and sign in. Open Messages, a conversation,
   then + → Rally. The extension rereads the shared access-token snapshot.

Only the public Supabase project URL/key are bundled. The app owns token refresh
and logout. SDK sessions and the extension snapshot are stored in Keychain.
Supabase Auth is pinned to 2.55.1 through Swift Package Manager and Package.resolved.

## Verification

```sh
xcodebuild -project RallyMessages.xcodeproj -scheme RallyMessages \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath /tmp/rally-extension-build CODE_SIGNING_ALLOWED=NO build

swiftc -module-cache-path /tmp/rally-swift-module-cache \
  MessagesExtension/RallyIntegration.swift RallyMessagesApp/RallyAccountAPI.swift \
  RallyMessagesApp/RallyAuthConfiguration.swift Tests/RallyIntegrationChecks.swift \
  Tests/RallyHTTPChecks.swift -o /tmp/rally-integration-checks
/tmp/rally-integration-checks

xcrun swift-format lint --strict --recursive MessagesExtension RallyMessagesApp Tests
```

The unsigned build and simulated HTTP tests do not prove callback delivery,
Keychain provisioning, email delivery, or actual Messages insertion. Verify those
on a signed device, including sign-out, expired sessions, and returning to an
unfinished composer. See [integration details](MessagesExtension/INTEGRATION.md).

On September 9, 2026, the signed iPhone build succeeded after the account holder
resolved Apple's agreement requirement. Automatic provisioning created explicit
profiles for both development bundle IDs. Signature verification passed, and
both signed targets contain the matching App Group and shared Keychain group.
Email callback delivery, runtime session sharing, and Messages insertion still
require an end-to-end device run.

App icons and production signing identifiers remain release preparation work.
