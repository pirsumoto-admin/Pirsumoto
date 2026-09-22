'use strict';
const crypto = require('crypto');
const {sanitizeFields, getMissingFields, validateValues} = require('./vehicle-validation');
const terminal = new Set(['completed', 'canceled', 'failed']);
const validId = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value);
function fail(status, code) { const e = new Error(code); e.status = status; throw e; }
function createPublicationApi(admin, db) {
  async function authorize(req, body) {
    const token = /^Bearer (.+)$/.exec(req.headers.authorization || '')?.[1];
    if (!token) fail(401, 'authentication_required');
    let user;
    try { user = await admin.auth().verifyIdToken(token); } catch (_) { fail(401, 'invalid_token'); }
    if (!validId(body.deviceId)) fail(400, 'invalid_device');
    const device = await db.collection('remote_control_devices').doc(body.deviceId).get();
    if (!device.exists || device.data().ownerUid !== user.uid) fail(403, 'device_not_authorized');
    // Persistent per-user minute budget works across function instances.
    // Draft conversation traffic must not exhaust a running worker's OCR budget.
    const bucket = body.action==='claim_publication' ? 'dispatch' : body.action==='control_publication' ? 'control' :
      ['worker_ocr','extract_description','agent_config'].includes(body.action) ? 'worker' : 'chat';
    const limit = db.collection('remote_validation_limits').doc(`${user.uid}_${body.deviceId}_${bucket}`);
    const minute = Math.floor(Date.now() / 60000);
    await db.runTransaction(async tx => {
      const snap = await tx.get(limit), old = snap.data();
      const count = old?.minute === minute ? old.count : 0;
      if (count >= 60) fail(429, 'rate_limit');
      tx.set(limit, {minute, count:count+1});
    });
    return user.uid;
  }
  async function handle(body, uid) {
    const {deviceId, requestId, attemptId, action} = body;
    if (action === 'claim_publication') {
      if (!validId(body.workerRunId)) fail(400, 'invalid_worker');
      const deviceRef = db.collection('remote_chats').doc(deviceId);
      const queueRef = db.collection('remote_publication_queues').doc(deviceId);
      const ownerRef = db.collection('remote_control_devices').doc(deviceId);
      return db.runTransaction(async tx => {
        const owner = (await tx.get(ownerRef)).data();
        if (owner?.ownerUid !== uid) fail(403, 'device_not_authorized');
        const device = (await tx.get(deviceRef)).data();
        // Busy workers never read queued cars or queue metadata, even on a retry.
        if (device?.activeRequestId) return {ok:true, request:null};
        const queue = (await tx.get(queueRef)).data();
        const requests = deviceRef.collection('requests');
        let selected;
        if (queue?.ownerUid === uid && validId(queue.nextRequestId)) {
          const priority = await tx.get(requests.doc(queue.nextRequestId));
          if (priority.data()?.ownerUid === uid && priority.data()?.state === 'queued' && priority.data()?.archived !== true) selected = priority;
        }
        if (!selected) {
          const fifo = requests.where('ownerUid','==',uid)
            .where('state','==','queued').orderBy('enqueuedAt').limit(25);
          let page = fifo;
          // Legacy deleted requests may still say queued. Skip them, including
          // full pages, without exposing any queue documents to the worker.
          while (!selected) {
            const candidates = await tx.get(page);
            selected = candidates.docs.find(doc => doc.data().archived !== true);
            if (selected || candidates.docs.length < 25) break;
            page = fifo.startAfter(candidates.docs.at(-1));
          }
        }
        if (!selected) return {ok:true, request:null};
        const data = selected.data();
        const update = {state:'preparing', workerRunId:body.workerRunId,
          revision:data.revision+1, lastMessage:'בודק פרטים ותמונות',
          updatedAt:admin.firestore.FieldValue.serverTimestamp()};
        tx.set(deviceRef, {activeRequestId:selected.id, workerRunId:body.workerRunId,
          leaseUntil:admin.firestore.Timestamp.fromMillis(Date.now()+60000)}, {merge:true});
        tx.update(selected.ref, update);
        if (queue?.nextRequestId === selected.id) tx.set(queueRef,{nextRequestId:null},{merge:true});
        // Only the car atomically reserved for immediate preparation reaches the phone.
        return {ok:true, request:{...data,...update,requestId:selected.id,updatedAt:null}};
      });
    }
    if (!validId(requestId) || !validId(attemptId)) fail(400, 'invalid_request');
    const ref = db.collection('remote_chats').doc(deviceId).collection('requests').doc(requestId);
    if (action === 'enqueue_publication') {
      // A timeout retry must also succeed after media retention has expired.
      const prior = await ref.get();
      if (prior.exists) {
        if (prior.data().ownerUid !== uid) fail(403, 'request_not_authorized');
        if (prior.data().attemptId === attemptId || !terminal.has(prior.data().state)) {
          return {ok:true, request:prior.data()};
        }
      }
      const vehicleData = sanitizeFields(body.vehicleData, {allowPlate:true});
      if (getMissingFields(vehicleData).length || validateValues(vehicleData).length) fail(400, 'invalid_vehicle');
      const attachments = body.attachments;
      if (!Array.isArray(attachments) || attachments.length < 1 || attachments.length > 20) fail(400, 'invalid_attachments');
      const prefix = `publication_media/${uid}/${deviceId}/${requestId}/${attemptId}/`;
      const paths = new Set();
      for (const item of attachments) {
        if (!item || typeof item.path !== 'string' || !item.path.startsWith(prefix) || !/^\d{1,2}$/.test(item.path.slice(prefix.length)) || paths.has(item.path) || !Number.isInteger(item.size) || item.size < 1 || item.size > 15*1024*1024 || !/^[a-f0-9]{64}$/.test(item.sha256 || '')) fail(400, 'invalid_attachment');
        paths.add(item.path);
        const [metadata] = await admin.storage().bucket().file(item.path).getMetadata();
        if (Number(metadata.size) !== item.size || !String(metadata.contentType).startsWith('image/')) fail(400, 'attachment_not_ready');
        item.generation = String(metadata.generation);
      }
      return db.runTransaction(async tx => {
        const existing = await tx.get(ref);
        // A non-terminal request cannot be republished by a double tap or concurrent controller.
        if (existing.exists) {
          if (existing.data().ownerUid !== uid) fail(403, 'request_not_authorized');
          if (existing.data().attemptId === attemptId || !terminal.has(existing.data().state)) {
            return {ok:true, request:existing.data()};
          }
        }
        const prevRev = (existing.exists && Number.isInteger(existing.data().revision)) ? existing.data().revision : 0;
        const data = {protocolVersion:1, ownerUid:uid, deviceId, requestId, sessionId:requestId, attemptId,
          state:'queued', archived:false, revision:prevRev+1, vehicleData, attachments:attachments.map(({path,size,sha256,generation})=>({path,size,sha256,generation})),
          platforms:['yad2','facebook'], completedPlatforms:[], enqueuedAt:admin.firestore.FieldValue.serverTimestamp(),
          updatedAt:admin.firestore.FieldValue.serverTimestamp(), lastMessage:'הבקשה נקלטה, ממתין למכשיר הפרסום'};
        tx.set(ref, data);
        return {ok:true, request:{...data, enqueuedAt:null, updatedAt:null}};
      });
    }
    if (action === 'prioritize_publication') {
      const queueRef=db.collection('remote_publication_queues').doc(deviceId);
      await db.runTransaction(async tx => {
        const data=(await tx.get(ref)).data();
        if(!data || data.ownerUid!==uid || data.attemptId!==attemptId || data.state!=='queued' || data.archived===true) fail(409,'request_not_queued');
        tx.set(queueRef,{ownerUid:uid,nextRequestId:requestId},{merge:true});
      });
      return {ok:true};
    }
    if (action === 'archive_publication') {
      const queueRef=db.collection('remote_publication_queues').doc(deviceId);
      await db.runTransaction(async tx => {
        const data = (await tx.get(ref)).data();
        if (!data || data.ownerUid !== uid || data.attemptId !== attemptId) fail(409, 'stale_request');
        if (!terminal.has(data.state)) fail(409, 'request_still_active');
        const queue=(await tx.get(queueRef)).data();
        tx.update(ref, {archived:true,revision:data.revision+1});
        if (queue?.nextRequestId===requestId) tx.set(queueRef,{nextRequestId:null},{merge:true});
      });
      return {ok:true};
    }
    if (action !== 'control_publication' || !['pause','resume','cancel'].includes(body.command)) fail(400, 'invalid_command');
    return db.runTransaction(async tx => {
      const snap = await tx.get(ref), data = snap.data();
      if (!data || data.ownerUid !== uid || data.attemptId !== attemptId) fail(409, 'stale_request');
      if (terminal.has(data.state)) return {ok:true, request:data};
      if (body.command === 'resume' && !['paused','stuck'].includes(data.state)) fail(409, 'cannot_resume');
      if (body.command === 'pause' && !['preparing','publishing'].includes(data.state)) fail(409, 'cannot_pause');
      if (data.state === 'canceling' && body.command !== 'cancel') fail(409, 'cancel_in_progress');
      if(data.control?.command===body.command && data.control.id!==data.appliedControlId) return {ok:true,request:data};
      const update = {updatedAt:admin.firestore.FieldValue.serverTimestamp(), revision:data.revision+1};
      if (data.state === 'queued') {
        if (body.command !== 'cancel') fail(409, 'request_not_active');
        Object.assign(update, {state:'canceled',lastMessage:'הבקשה בוטלה לפני הפרסום'});
      } else {
        if (body.command === 'cancel') Object.assign(update, {state:'canceling',lastMessage:'ממתין לאישור ביטול מהמכשיר'});
        update.control = {id:crypto.randomUUID(),command:body.command,attemptId};
      }
      tx.update(ref, update);
      return {ok:true, request:{...data,...update}};
    });
  }
  return {authorize,handle};
}
module.exports = {createPublicationApi, validId};
