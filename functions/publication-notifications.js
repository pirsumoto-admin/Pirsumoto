const crypto = require('node:crypto');

const STATUS_STATES = new Set([
  'preparing', 'publishing', 'paused', 'stuck', 'canceling',
  'canceled', 'failed', 'completed',
]);

// Let Android/APNs display the alert without launching Dart or reading
// Firestore. Keep vehicle/chat details out of the system-rendered payload:
// the app validates the signed-in owner before opening the request.
function publicationMessage(after, {deviceId, requestId}, tokens) {
  const thread = crypto.createHash('sha256')
    .update(`${after.ownerUid}/${deviceId}/${requestId}`).digest('hex');
  return {
    tokens,
    notification: {
      title: 'פרסומוטו',
      body: 'מצב בקשת הפרסום עודכן. פתחו את האפליקציה לצפייה בעדכון.',
    },
    android: {
      priority: 'high',
      notification: {
        channelId: 'pirsumoto_chat_notifications',
        tag: thread,
        notificationPriority: 'PRIORITY_LOW',
        defaultSound: false,
      },
    },
    apns: {
      headers: {
        'apns-push-type': 'alert',
        'apns-priority': '5',
        'apns-collapse-id': thread,
      },
      payload: {aps: {threadId: thread}},
    },
    data: {
      ownerUid: after.ownerUid,
      deviceId,
      sessionId: requestId,
      attemptId: after.attemptId,
      state: after.state,
      revision: String(after.revision),
    },
  };
}

async function sendPublicationNotification(event, db, messaging, logger = console) {
  const before = event.data.before.data();
  const after = event.data.after.data();
  const context = {eventId: event.id, state: after.state, revision: after.revision};
  if (before.state === after.state || !STATUS_STATES.has(after.state)) {
    logger.info('publication_notification_skipped', {...context, reason: 'not_a_status_transition'});
    return;
  }
  const latest = (await event.data.after.ref.get()).data();
  if (!latest || latest.revision !== after.revision || latest.archived ||
      latest.ownerUid !== after.ownerUid || latest.attemptId !== after.attemptId) {
    logger.info('publication_notification_skipped', {...context, reason: 'stale_or_archived'});
    return;
  }
  const tokens = await db.collection('notification_tokens')
    .where('ownerUid', '==', after.ownerUid).get();
  if (tokens.docs.length === 0) {
    logger.warn('publication_notification_no_tokens', context);
    return;
  }
  for (let i = 0; i < tokens.docs.length; i += 500) {
    const batch = tokens.docs.slice(i, i + 500);
    const result = await messaging.sendEachForMulticast(
      publicationMessage(after, event.params, batch.map(doc => doc.data().token)),
    );
    const errors = {};
    let acceptedCount = 0;
    for (const response of result.responses) {
      if (response.success) {
        acceptedCount++;
      } else {
        const code = response.error?.code || 'unknown';
        errors[code] = (errors[code] || 0) + 1;
      }
    }
    // FCM acceptance is not proof of display on the device. Never log tokens
    // or message contents, but make missing registrations and send failures visible.
    const summary = {...context, tokenCount: batch.length, acceptedCount,
      failureCount: batch.length - acceptedCount, errors};
    if (summary.failureCount) logger.warn('publication_notification_send_result', summary);
    else logger.info('publication_notification_send_result', summary);
    await Promise.all(result.responses.map((response, index) =>
      ['messaging/registration-token-not-registered', 'messaging/invalid-registration-token']
        .includes(response.error?.code)
        ? batch[index].ref.delete() : Promise.resolve()));
  }
}

module.exports = {publicationMessage, sendPublicationNotification};
