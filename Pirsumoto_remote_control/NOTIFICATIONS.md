# Status notification delivery

The controller uses OS-displayed FCM notification messages for background and
terminated delivery. Foreground pushes and Firestore updates share the local
notification/revision deduplication path. Only the currently visible chat
suppresses foreground alerts. Background notification text is deliberately
generic; opening the app checks the signed-in owner before showing the chat.

## Rollout

Both the controller and the Cloud Function must be updated. A controller-only
update leaves the old data-only sender in place.

Android must also have a Firebase Android app registered with the exact package
`com.pirsumoto.remote.pirsumoto_remote_control`. Download its `google-services.json`
to `android/app/` and keep `DefaultFirebaseOptions.android` synchronized with that
client. The main app's JSON/app ID is not the controller's configuration. The
Google Services Gradle plugin generates the resources used by Firebase's native
startup provider before Dart runs; Dart initialization alone does not supply those
resources to a newly started background process.

1. Build and install the controller, open it, sign in, and grant notification
   permission. The app registers its FCM token for the signed-in owner once a
   paired device is available. Failed registration retries every 30 seconds
   and when the app resumes.
2. Deploy only the notification function from the shared backend:

   ```sh
   cd /Users/jotit/Desktop/Pirsumoto/functions
   firebase deploy --project car-publisher --only functions:publicationNotifications
   ```

3. For iOS, enable Push Notifications for the controller's Apple App ID and
   use a provisioning profile containing the push entitlement. Upload a valid
   APNs authentication key for the controller app in Firebase Project Settings
   > Cloud Messaging. Xcode's signing/export process chooses the APNs environment
   for the provisioning profile; the checked-in entitlement is for development.

The deployed function's runtime service account also needs
`cloudmessaging.messages.create` in `car-publisher`. The predefined
`roles/firebasecloudmessaging.admin` role includes this permission. Check the
account named in the function's runtime settings: successful deployment or a
Firestore trigger invocation does not grant FCM send access. This project's
notification function currently runs as
`265879971574-compute@developer.gserviceaccount.com`, a shared service account.
Any IAM change to that account must account for its other workloads.

## Device verification

On Android and an APNs-enabled iPhone, trigger a real publication state change
from the main app in each of these conditions:

- Controller foregrounded outside the target chat: one detailed local alert.
- Target chat visible: no interrupting foreground alert.
- Home screen or phone locked with that chat still mounted: a system alert.
- Controller process terminated: a system alert; tapping it opens the request.
- Sign out or switch owners: no access to the previous owner's request.

Also verify two controllers signed into the same owner and a separate owner's
controller; only the intended owner's registered installations should receive
the push. Rapid updates for one request replace its background notification.

Android force-stop from system Settings blocks delivery until the user reopens
the app. OS notification permission/channel settings must allow alerts. Unit
tests and simulator builds do not validate live FCM/APNs delivery.

## Delivery diagnostics

The controller logs notification authorization and successful token registration
under `[Notifications]`, without printing the token. After deploying the updated
function, look for these structured log messages:

- `publication_notification_no_tokens`: the owner has no registered controller
  token; no push was sent.
- `publication_notification_skipped`: a non-status transition or a stale/archived
  request was intentionally ignored.
- `publication_notification_send_result`: `acceptedCount`, `failureCount`, and
  error-code counts show whether FCM accepted the sends. Acceptance still does
  not prove the phone displayed them.

References: [Firebase message types](https://firebase.google.com/docs/cloud-messaging/customize-messages/set-message-type),
[Flutter setup](https://firebase.google.com/docs/cloud-messaging/flutter/get-started),
[receiving and opening notifications](https://firebase.google.com/docs/cloud-messaging/flutter/receive-messages).
See also [FCM IAM roles and permissions](https://docs.cloud.google.com/iam/docs/roles-permissions/firebasecloudmessaging).
