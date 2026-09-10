# Rally

Drive the plan out of the group chat.

Rally is an iOS app and iMessage extension for making plans with friends. Choose
an activity, find a time and place, and share a Rally in your conversation.
Friends respond on the [Rally website](https://rally-your-friends.com) without
needing an account or the app.

## Features

- Create plans in Messages with a specific time or a poll.
- Find a location with Google Places autocomplete, or leave it open for suggestions.
- Sign in by email to save private drafts and share plans.
- Track plans under Needs You, Active, and Past.
- Review responses, confirm the details, and share the final plan.
- Add confirmed plans to Calendar with the time, place, and Rally link filled in.

## Getting started

Development requires macOS and Xcode. The app targets iOS 17 and later.

1. Open `RallyMessages.xcodeproj` and let Xcode resolve the Swift packages.
2. Select your development team for both the `RallyMessages` and
   `RallyMessagesExtension` targets. Configure bundle identifiers and provisioning
   profiles that support their App Groups and Keychain Sharing capabilities.
3. Review the authentication configuration described below.
4. Run the `RallyMessages` scheme on your iPhone. The welcome screen explains how
   to create a Rally; tap **See your rallies** to sign up or log in.
5. Open a conversation in Messages and choose **+ → Rally** to create a plan.

The extension inserts the plan's title and link into your message. Tap Send when
you are ready to share it. Save a draft before leaving an unfinished composer;
unsaved changes are held in memory.

Once a plan is confirmed, open it in Rally and tap **Add to Calendar**. Review the
event, choose a calendar, and tap **Add** to save, or **Cancel** to return to Rally.
Events default to one hour; you can adjust the end time in the calendar editor.
Calendar events are separate copies and do not automatically update if you cancel
or delete a Rally.

### Backend and sign-in

This repository contains the native clients. The website and backend live in
[rally-your-friends](https://github.com/ranjinipnarayan/rally-your-friends).

Email sign-in uses Supabase Auth. The project URL, publishable key, and callback
URL are defined in [RallyAuthConfiguration.swift](RallyMessagesApp/RallyAuthConfiguration.swift).
For your own backend, update that configuration and the API endpoints in
[RallyIntegration.swift](MessagesExtension/RallyIntegration.swift) and
[RallyAccountAPI.swift](RallyMessagesApp/RallyAccountAPI.swift), including the
allowed public-link hosts.

The callback URL must be allowed in your Supabase project's authentication
redirect settings. If you change the development bundle identifiers, update the
app's URL scheme, callback URL, and both targets' shared entitlements together.
Sign in with the email's one-time code or open its link on the device that
requested it. Choose **I already have a code** to enter a code requested on the
website or another device, using the same email address.

### Optional location autocomplete

To enable Google Places autocomplete:

1. Enable billing and **Places API (New)** in your Google Cloud project.
2. Create an API key restricted to **iOS apps**, allowing both targets' bundle
   identifiers, and restrict API access to **Places API (New)**.
3. Create your local configuration:

   ```sh
   cp Configuration/Secrets.xcconfig.example Configuration/Secrets.xcconfig
   ```

4. Set `GOOGLE_PLACES_API_KEY` in that file and rebuild.

`Secrets.xcconfig` is ignored by Git. Manual location entry works without a key.

## Development checks

Build for the simulator without signing:

```sh
xcodebuild -project RallyMessages.xcodeproj -scheme RallyMessages \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath /tmp/rally-extension-build CODE_SIGNING_ALLOWED=NO build
```

Run the integration and autocomplete checks:

```sh
swiftc -module-cache-path /tmp/rally-swift-module-cache \
  Shared/RallyLocation.swift \
  MessagesExtension/RallyIntegration.swift RallyMessagesApp/RallyAccountAPI.swift \
  RallyMessagesApp/RallyAuthConfiguration.swift Tests/RallyIntegrationChecks.swift \
  Tests/RallyHTTPChecks.swift -o /tmp/rally-integration-checks
/tmp/rally-integration-checks

swiftc -module-cache-path /tmp/rally-swift-module-cache \
  Shared/RallyLocation.swift Shared/LocationAutocompleteModel.swift \
  Tests/LocationAutocompleteChecks.swift \
  -o /tmp/rally-autocomplete-checks
/tmp/rally-autocomplete-checks

swiftc -module-cache-path /tmp/rally-swift-module-cache \
  Shared/RallyLocation.swift RallyMessagesApp/RallyAccountAPI.swift \
  RallyMessagesApp/RallyCalendarEvent.swift Tests/RallyCalendarChecks.swift \
  -o /tmp/rally-calendar-checks
/tmp/rally-calendar-checks
```

After the simulator build, run the mocked email link/code sign-in checks with
a simulator already running:

```sh
bash Tests/run-auth-checks.sh /tmp/rally-extension-build
```

Check Swift formatting:

```sh
xcrun swift-format lint --strict --recursive MessagesExtension RallyMessagesApp Shared Tests
```

Use a signed device to verify email callbacks, shared sign-in, and message
insertion. See [integration details](MessagesExtension/INTEGRATION.md) for the
API contract and extension behavior.
