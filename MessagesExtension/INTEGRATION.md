# iMessage integration handoff

The extension keeps its black-and-white structured steps. Creation choices were
checked against `ranjinipnarayan/rally-your-friends` (`src/routes/index.tsx` and
`src/lib/rally-shared.ts`) and the deployed website on September 8, 2026.

Supported choices: specific time or poll; This week / This weekend / Next week;
Morning / Afternoon / Evening; edit, remove, and regenerate poll options;
specific location or leave open. Empty specific locations become “To be decided.”
Polls start with three options and can be reduced to one or two. Weekend options
are the next Friday, Saturday, and Sunday together, matching the website.
Place entry now supports Google Places autocomplete while retaining manual text
entry. The selected text uses the existing API location field. See README for
the restricted-key setup; no recommendations or map views are added.

## API v1

`RallyAPI` implements `RallyCreating.create` using the production endpoint
`POST https://rally-your-friends.com/api/v1/rallies`. The contract is
[docs/api.md](https://github.com/ranjinipnarayan/rally-your-friends/blob/main/docs/api.md).
It sends the shared user access token as a Bearer credential, JSON content type,
and `Accept: application/json`. It uses an ephemeral, cookie-free session and
refuses redirects. No generated web RPC or direct database call is used.

API input mapping:

| Extension domain input | Website input |
| --- | --- |
| `activity` | `activity` |
| `scheduleMode` | `timeMode` (`specific` / `poll`) |
| `TimeZone.current.identifier` | `timeZone` |
| `specificDate` | `startsAt` (ISO 8601 instant or null) |
| `pollCandidates` | `candidates` (ISO 8601 instants) |
| `locationMode` | `locationMode` (`specific` / `open`) |
| `location` | `location` (null when open) |

Creating a Rally sends `status: "open"` and requires a valid plan. Creation POSTs
include the device's current timezone identifier as `timeZone` so link previews
can display local times. The extension creates plans directly; it does not save
or publish drafts. Existing drafts in the organizer app can be finished on the
website.
Absent time/location fields are encoded as explicit nulls. Dates are ISO 8601
instants in UTC, and payloads are checked against the 16 KiB limit. Creation
requires HTTP 201. The response decoder retains `id`, `title`, and `publicUrl`,
ignoring the private creator token. The API derives ownership from
authentication and owns lifecycle, `next_action`, responses, and finalization.

The organizer app deletes a Rally only after an explicit confirmation. It sends
`DELETE /api/v1/rallies/:id` with the owner's Bearer token and no body, accepts
`204 No Content` without JSON decoding, removes the local item, and refreshes
the list. An uncertain deletion requires a refresh before another attempt;
a subsequent `404` removes the unavailable detail from the native UI.

`publicURL` must be a public HTTPS recipient link. The current website uses
`/r/<inviteToken>`; `/m/<creatorToken>` is private and must never be shared. The
validator allows the apex and www Rally hosts, a 16–64 character lowercase
alphanumeric invite token, no query or fragment, and HTTPS's default port.
Update this validator with tests if the agreed API changes the public route.

API v1 does not support idempotency keys. Duplicate submissions are disabled.
Once creation succeeds, message-insertion retries reuse that saved result without
another POST. A network error, 5xx, unexpected status, or unreadable success
response may follow a saved creation, so the extension blocks further POSTs in
that composer and offers “Review My Rallies” on the website. It does not assume
failure or silently create another Rally. This guard and the unfinished plan are
in memory only; after restarting, check the organizer's Rallies before recreating
an uncertain plan. Durable cross-process recovery is not implemented.

Explicit API rejections (such as 400/409) preserve the plan for correction. A 401
requires signing in via the containing app; a stale rejection cannot sign out a
newly switched account or a refreshed session. Session changes cannot expose
another organizer's returned link. The app must own token refresh and logout.

`MessagesViewController` inserts plain text containing the returned title and
URL. It verifies that the conversation is still active before insertion. It
does not automatically send the message. Recipient responses happen on the web;
the old local response UI and URL-embedded plan data have been removed.

## Shared login

The app implements email link and one-time code login with the pinned Supabase
Auth SDK (2.55.1). Links use PKCE callback exchange; codes use email OTP
verification and can be entered after requesting an email in the app or through
**I already have a code** for an email requested elsewhere. Both paths verify
`/me` identity before sharing the session and use foreground token refresh.
The extension reads an access-token snapshot from the shared Keychain;
only the app refreshes the session. Tokens use WhenUnlockedThisDeviceOnly
accessibility and are never stored in defaults, links, or logs.

The form can be filled out before sign-in. Create Rally prompts
“Open Rally to sign in” if no valid shared session exists. The alert opens the
containing app. Returning to Messages rereads the shared session. The organizer
then taps Create Rally again. Unsaved form state survives only
while the extension process remains alive.

Both targets include App Group and Keychain entitlements. Provisioning and the
Supabase callback allowlist must be configured as described in [README](../README.md).
Actual device session sharing and callback delivery remain unverified.

## Validation

Build the containing app and embedded extension:

```sh
xcodebuild -project RallyMessages.xcodeproj -scheme RallyMessages \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath /tmp/rally-extension-build CODE_SIGNING_ALLOWED=NO build
```

Run integration checks on macOS without a Simulator:

```sh
swiftc -module-cache-path /tmp/rally-swift-module-cache \
  Shared/RallyLocation.swift \
  MessagesExtension/RallyIntegration.swift RallyMessagesApp/RallyAccountAPI.swift \
  RallyMessagesApp/RallyAuthConfiguration.swift Tests/RallyIntegrationChecks.swift \
  Tests/RallyHTTPChecks.swift \
  -o /tmp/rally-integration-checks
/tmp/rally-integration-checks
```

Checks cover all four HTTP creation branches, exact field names/nulls, bearer
headers, UTC dates, creation timezone and its omission from organizer updates,
incomplete-plan rejection, public URL validation, HTTP errors, ambiguous timeouts,
session gates, account changes during requests, and insertion retries.
A read-only production `/me` probe returned the documented 401 without credentials.
Authenticated production creation, shared Keychain provisioning, organizer-app
visibility, and actual Messages insertion still need a real shared session and
native device verification.

`bash Tests/run-auth-checks.sh /tmp/rally-extension-build` uses the simulator
build's pinned Auth SDK and a running simulator to test email-code verification,
the PKCE link callback, existing codes from another device, input validation,
expired/used-code and rate-limit errors, email changes, and the verified session
shared with Messages. Auth and organizer HTTP responses and secure storage are
mocked; it sends no emails and uses no live accounts.
