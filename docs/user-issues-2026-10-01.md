# Publication and remote-control fixes — 2026-10-01

The main application changes target Android. The controller changes cover Android and iOS, with live validation limited to the two supplied Android phones.

## Task breakdown

| Report | App | Task and implemented change | Validation / remaining work |
| --- | --- | --- | --- |
| 1 | Controller | Normalize camera/gallery photos to oriented, resized JPEG files before attaching them. Use native UIImage decoding for iOS HEIC. Display decode/save errors. | JPEG/PNG and invalid-image unit tests pass. iOS Swift syntax checked; the original iOS camera failure still needs an iPhone test. |
| 2 | Main | Keep login cookies/local storage when closing the WebView; flush cookies before destruction. Reset vehicle form state when the plate changes. | Browser lifecycle and vehicle reset regressions pass. Actual Facebook/Yad2 login persistence needs a real website session. |
| 3 | Main | Investigate the second-attempt “אינטנל סקרין” freeze. Session ownership and teardown now prevent overlapping browsers; unsuccessful completion pauses rather than claiming success. | The exact screen is unclear. A screenshot or the stage name is still needed to reproduce this particular report. |
| 4 | Controller | Exclude dealer ownership records from the calculated hand number. | Source calculation corrected; fixture-specific Ministry/Firestore comparison still pending. |
| 7 | Both | Require explicit resume-stage selection after a pause. Offer stages starting two phases before the current phase through completion. Verify site publication confirmation before reporting success. | Resume, worker pause, and completion verifier regressions pass. Backend deployment is needed for controller stage selection. |
| 10 | Controller | Put saving/saved/error feedback beside and below the details form and preserve saved feedback when the next chat message replaces the form. | Widget test passes. |
| 11, 18 | Main | Dismiss the keyboard before resolving Yad2 popup/button bounds. Verify additional-info text after entry; advance only when the price page is present. Verify the terms checkbox before submission. | Additional-info, readback-failure, keyboard, and resume regressions pass. Website runtime changes still require a live publication check. |
| 12, 14 | Main | Clear descriptions between different vehicles and use only the current Yad2 engine’s description for Facebook. Preserve the current request’s final description for a parked restart. | Vehicle reset and publication contract tests pass. |
| 15, 16 | Both | Recover disconnected WebRTC peers after a grace period, reset dimensions when reconnecting, reconnect on foreground return, and dispose connections owned by a closed controller route. | Live stream, background/foreground return, and actual remote touch input verified on both supplied phones. |
| 17 | Both/backend | Add “השאר מושהה והמשך בתור”. Drain/close the paused browser, release its queue reservation, retain request/media, and restart the unfinished platform when requeued. | Worker/queue/backend tests pass. Requires backend deployment. Check whether the paused ad already went live before restarting it. |
| 21 | Main | Remove automatic automation resume when takeover ends or the remote session disconnects. Resume remains an explicit command with selected stage. | Regression confirms disconnect leaves publication paused. |
| 23 | Controller/backend | Add optional vehicle highlights (“חשוב לדעת”), allow clearing them, preserve them through extraction/request validation, and incorporate them into the publication description. | Form and backend tests pass. Requires backend deployment for the full server contract. |
| 24 | Controller/backend | Guard overlapping recording actions, show microphone/recording/transcription errors, and reject unsuccessful transcription API responses explicitly. | Recording started successfully and showed its running timer on the controller phone; canceled without submitting test audio. Spoken-audio transcription still needs a recording test against the deployed backend. |
| New: 15-minute expiry | Main | Schedule a per-attempt Android alarm plus foreground timer. Fence callbacks and browser ownership by session token. Cancel on terminal/canceled sessions; preserve the remaining time between Yad2 and Facebook. On expiry stop page activity, drain automation, forcibly clean up after a failed drain, and return home. | Virtual-time tests cover 15 minutes and stale deadlines; lifecycle regression covers stuck drain and successor protection. Final Kotlin/Android build passes. Exact alarms depend on Android permission; the backup alarm may be delayed in Doze without it. |
| New: kiosk updates/restarts | Main | Preserve the previous update policy and install restriction, postpone system updates and block app installation while device-owner kiosk mode is active, then restore prior policy on explicit kiosk exit. | Android build passes. Supplied main phone is not device owner, so policy behavior could not be exercised. Android postponement is limited to 30 days; standard DPC APIs cannot guarantee prevention of all Samsung automatic restarts. Knox management is needed for that guarantee. |

## Phone validation

- `RFCY21TSJNZ`: final controller debug APK installed with the existing signing identity; existing data/account preserved.
- `adb-R5CR61E6C6J-q3EC7Y._adb-tls-connect._tcp`: final main release APK installed; existing data/account preserved.
- Both applications launched successfully. Controller connected to the main phone and received live video. Stream survived controller background/foreground return. Taking control and tapping the streamed vehicle-details button changed the main phone’s screen correctly.
- Controller microphone recording started, and the recording timer advanced. The test was canceled rather than submitted as vehicle information.
- The authenticated controller currently lists the main phone as `android_22bac8946a0115de`. This differs from the requested Firestore fixture `remote_control_devices/android_9fd953f78a149665`.
- No new real vehicle listing was published during validation.

## Deployment and validation limits

Firebase CLI and local Google credentials have expired. Direct inspection of the requested Firestore fixture and deployment of the changed `remoteValidation` function remain pending `firebase login --reauth`. The installed client changes that depend on the new backend contract (parked queue continuation, controller resume-stage commands, highlights) require that deployment to function end to end.

The main analyzer has existing warnings/information diagnostics but no errors; the controller analyzer has no errors. The issue-related main regression suite passed 88 tests, the full controller suite passed 36 tests, and all backend tests passed 31 tests. The untouched main `widget_test.dart` is an old counter-template test and is outside the targeted validation.

Android references: [system update policies](https://developer.android.com/work/dpc/system-updates), [exact alarm requirements](https://developer.android.com/develop/background-work/services/alarms). Samsung restart management: [Knox Service Plugin policies](https://docs.samsungknox.com/admin/knox-platform-for-enterprise/knox-service-plugin/release-notes/26-08/).
