'use strict';
const terminal = new Set(['completed', 'canceled', 'failed']);
const day = 24 * 60 * 60 * 1000;

// Retain unfinished jobs indefinitely. Abandoned uploads expire after seven days;
// terminal request media expires thirty days after its last state update.
function mediaExpired(name, metadata, request, now = Date.now()) {
  const parts = name.split('/');
  if (parts.length !== 6 || parts[0] !== 'publication_media') return false;
  const [, owner, , , attempt] = parts;
  const created = Date.parse(metadata.timeCreated);
  if (!Number.isFinite(created)) return false;
  if (!request || request.ownerUid !== owner || request.attemptId !== attempt) return now - created > 7 * day;
  const updated = request.updatedAt?.toMillis?.();
  return terminal.has(request.state) && Number.isFinite(updated) && now - updated > 30 * day;
}

async function cleanupPublicationMedia(admin, db) {
  const cursorRef = db.collection('publication_maintenance').doc('media_cursor');
  let pageToken = (await cursorRef.get()).data()?.pageToken;
  const bucket = admin.storage().bucket();
  // Bound work per invocation and resume the scan on the next daily run.
  for (let page = 0; page < 20; page++) {
    const [files, next] = await bucket.getFiles({prefix:'publication_media/', maxResults:200, autoPaginate:false, ...(pageToken ? {pageToken} : {})});
    for (const file of files) {
      const parts = file.name.split('/');
      if (parts.length !== 6) continue;
      const [, , deviceId, requestId] = parts;
      try {
        const [metadata] = await file.getMetadata();
        const request = (await db.collection('remote_chats').doc(deviceId).collection('requests').doc(requestId).get()).data();
        if (mediaExpired(file.name, metadata, request)) {
          // A concurrent replacement must never be deleted by an old scan.
          await file.delete({ifGenerationMatch:metadata.generation});
        }
      } catch (error) {
        if (![404,412].includes(Number(error.code))) throw error;
      }
    }
    pageToken = next?.pageToken;
    await cursorRef.set({pageToken:pageToken || null});
    if (!pageToken) break;
  }
}
module.exports = {mediaExpired, cleanupPublicationMedia};
