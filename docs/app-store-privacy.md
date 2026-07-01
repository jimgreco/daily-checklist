# App Store Privacy Checklist

Use this source-controlled checklist when updating App Store Connect privacy answers.

## Data Linked to the User

Ritual Cue uses this data for app functionality only. It is not used for tracking or third-party advertising.

- Contact Info: name, email address from Google or Apple sign-in.
- User ID: Ritual Cue's account identifier and provider identity mapping.
- User Content: checklist items, groups, notes, completion history, reminder settings, and sync metadata.

## Data Not Collected

- Location
- Contacts
- Photos or videos
- Audio
- Health and fitness
- Financial information
- Purchases
- Search history
- Browsing history
- Diagnostics
- Advertising data

## Local Data

The iOS app stores offline checklist data in app documents storage, uses UserDefaults for app preferences and device/account identifiers, and stores access and refresh tokens in Keychain. The web app stores offline checklist data in browser storage and keeps the refresh token in an HttpOnly cookie.

## User Controls

Signed-in users can export synced checklist data and delete their server-side account from Account. Public support and privacy pages are available at:

- `https://ritualcue.com/privacy.html`
- `https://ritualcue.com/support.html`
