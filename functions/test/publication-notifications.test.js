const test = require('node:test');
const assert = require('node:assert/strict');
const {publicationMessage, sendPublicationNotification} = require('../publication-notifications');

const after = {
  ownerUid: 'owner', attemptId: 'attempt', state: 'completed', revision: 5,
  lastMessage: 'Private vehicle and customer details',
};
const params = {deviceId: 'device', requestId: 'request'};

function fixture({before = {state: 'publishing'}, current = after, count = 1, responses} = {}) {
  const sent = [], deleted = [], queries = [];
  const event = {
    params,
    data: {
      before: {data: () => before},
      after: {data: () => after, ref: {get: async () => ({data: () => current})}},
    },
  };
  const db = {collection(name) {
    assert.equal(name, 'notification_tokens');
    return {where(...args) {
      queries.push(args);
      return {get: async () => ({docs: Array.from({length: count}, (_, i) => ({
        data: () => ({token: `token${i}`}),
        ref: {delete: async () => deleted.push(i)},
      }))})};
    }};
  }};
  const messaging = {sendEachForMulticast: async message => {
    sent.push(message);
    return {responses: responses || message.tokens.map(() => ({success: true}))};
  }};
  return {event, db, messaging, sent, deleted, queries};
}

test('background delivery has a visible alert on both platforms without private text', () => {
  const message = publicationMessage(after, params, ['token']);
  assert.ok(message.notification.title);
  assert.ok(message.notification.body);
  assert.equal(message.android.priority, 'high');
  assert.equal(message.android.notification.channelId, 'pirsumoto_chat_notifications');
  assert.equal(message.android.notification.notificationPriority, 'PRIORITY_LOW');
  assert.equal(message.android.notification.defaultSound, false);
  assert.equal(message.android.notification.sound, undefined);
  assert.equal(message.apns.headers['apns-push-type'], 'alert');
  assert.equal(message.apns.headers['apns-priority'], '5');
  assert.equal(message.apns.payload.aps.sound, undefined);
  assert.equal(JSON.stringify(message).includes(after.lastMessage), false);
  assert.deepEqual(message.data, {
    ownerUid: 'owner', deviceId: 'device', sessionId: 'request',
    attemptId: 'attempt', state: 'completed', revision: '5',
  });
});

test('updates replace the same request alert and keep separate requests distinct', () => {
  const key = publicationMessage(after, params, []).apns.headers['apns-collapse-id'];
  assert.ok(Buffer.byteLength(key) <= 64);
  assert.equal(publicationMessage({...after, revision: 6}, params, []).android.notification.tag, key);
  assert.notEqual(publicationMessage(after, {...params, requestId: 'other'}, []).android.notification.tag, key);
});

test('only the owner tokens receive the update, batched at the FCM limit', async () => {
  const f = fixture({count: 501});
  await sendPublicationNotification(f.event, f.db, f.messaging);
  assert.deepEqual(f.queries, [['ownerUid', '==', 'owner']]);
  assert.deepEqual(f.sent.map(m => m.tokens.length), [500, 1]);
});

test('unchanged, stale, archived, deleted and replaced requests do not alert', async () => {
  for (const options of [
    {before: after}, {current: null}, {current: {...after, revision: 6}},
    {current: {...after, archived: true}}, {current: {...after, ownerUid: 'other'}},
    {current: {...after, attemptId: 'retry'}}, {count: 0},
  ]) {
    const f = fixture(options);
    await sendPublicationNotification(f.event, f.db, f.messaging);
    assert.equal(f.sent.length, 0);
  }
});

test('invalid tokens are removed; temporary delivery failures retain their tokens', async () => {
  const f = fixture({count: 3, responses: [
    {error: {code: 'messaging/registration-token-not-registered'}},
    {error: {code: 'messaging/internal-error'}},
    {success: true},
  ]});
  await sendPublicationNotification(f.event, f.db, f.messaging);
  assert.deepEqual(f.deleted, [0]);
});


test('logs distinguish an invoked trigger with no tokens from FCM rejection or acceptance', async () => {
  for (const count of [0, 2]) {
    const f = fixture({count, responses: [
      {success: true}, {error: {code: 'messaging/mismatched-credential'}},
    ]});
    const logs = [];
    const logger = {info: (...args) => logs.push(args), warn: (...args) => logs.push(args)};
    await sendPublicationNotification(f.event, f.db, f.messaging, logger);
    if (!count) {
      assert.equal(logs[0][0], 'publication_notification_no_tokens');
    } else {
      assert.equal(logs[0][0], 'publication_notification_send_result');
      assert.equal(logs[0][1].acceptedCount, 1);
      assert.deepEqual(logs[0][1].errors, {'messaging/mismatched-credential': 1});
    }
    assert.equal(JSON.stringify(logs).includes('token0'), false);
    assert.equal(JSON.stringify(logs).includes(after.lastMessage), false);
  }
});
