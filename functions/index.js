const functions = require('@google-cloud/functions-framework');
const { PubSub } = require('@google-cloud/pubsub');
const crypto = require('crypto');

// Initialize Google Cloud Pub/Sub
const pubsub = new PubSub();
const TOPIC_NAME = 'whatsapp-incoming-messages';

// Read secret tokens from Cloud Environment Variables
const APP_SECRET = process.env.META_APP_SECRET;
const VERIFY_TOKEN = process.env.WHATSAPP_VERIFY_TOKEN;
const WHATSAPP_ACCESS_TOKEN = process.env.WHATSAPP_ACCESS_TOKEN;
const LOCAL_BRIDGE_TOKEN = process.env.PIRSUMOTO_LOCAL_BRIDGE_TOKEN;

// SECURITY WARNING: Move these keys to your Cloud Environment Variables in production!
const GEMINI_API_KEY = process.env.GEMINI_API_KEY || 'AQ.Ab8RN6I0DFFHKEIB6lMtXqVDYm_7OGg9r9-norHBsXGY-LbruA';
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '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';

// Cache to prevent duplicate webhook processing across rapid delivery attempts
const processedMessageIds = new Set();
// Stateful memory tracker to preserve chat listing history across turn boundaries
const userStates = new Map();

const INVENTORY_SYSTEM_PROMPT = `
  You are a rigid internal B2B inventory-validation engine backend for dealership staff. 
  Your single operational function is to validate incoming structural information from employees against 10 explicit database variables.
  
  Database Schema:
  1. license_plate (מספר רכב / לוחית רישוי)
  2. test_month (חודש טסט)
  3. test_year (שנת טסט)
  4. hand (יד)
  5. current_ownership (בעלות נוכחית)
  6. previous_ownership (בעלות קודמת)
  7. km (קילומטראז')
  8. price (מחיר)
  9. description (תיאור חופשי)
  10. gear_type (סוג גיר - strictly: אוטומטי or ידני)

  Task Execution:
  1. Compare incoming employee input against the current historical tracking object state.
  2. Map newly discovered inventory details strictly into vacant property fields. Do not alter existing parameters unless explicitly requested.
  3. Keep your response message strictly professional, structured, and focused entirely on data integrity. Do not chat or offer conversational remarks.
  
  Response Constraints:
  You MUST respond with a valid JSON schema conforming exactly to this structure:
  {
    "updated_state": {
      "license_plate": string or null,
      "test_month": string or null,
      "test_year": string or null,
      "hand": string or null,
      "current_ownership": string or null,
      "previous_ownership": string or null,
      "km": string or null,
      "price": string or null,
      "description": string or null,
      "gear_type": string or null
    },
    "reply_hebrew": "A precise, clean system notification listing remaining parameters missing from the database record. Keep phrasing administrative and direct."
  }
  
  If all parameters are successfully captured, output a complete inventory record breakdown sheet in Hebrew, confirming auto-publication payload execution. At the very end of your Hebrew notification string, you must always append this exact administrative instruction line: '\\n\\n*לעצירת עדכון נתונים השב 0*'"
`;

function createEmptyInventoryState() {
  return {
    license_plate: null,
    test_month: null,
    test_year: null,
    hand: null,
    current_ownership: null,
    previous_ownership: null,
    km: null,
    price: null,
    description: null,
    gear_type: null
  };
}

function rememberMessageId(messageId) {
  if (!messageId) return true;
  if (processedMessageIds.has(messageId)) return false;
  processedMessageIds.add(messageId);

  if (processedMessageIds.size > 5000) {
    const firstElement = processedMessageIds.values().next().value;
    processedMessageIds.delete(firstElement);
  }
  return true;
}

function parseModelJson(jsonText) {
  const trimmed = jsonText
    .trim()
    .replace(/^```json\s*/i, '')
    .replace(/^```\s*/i, '')
    .replace(/\s*```$/i, '')
    .trim();
  return JSON.parse(trimmed);
}

async function transcribeAudioBuffer(audioBuffer, mimeType = 'audio/ogg', filename = 'audio.ogg') {
  const formData = new FormData();
  const audioBlob = new Blob([audioBuffer], { type: mimeType });
  formData.append('file', audioBlob, filename);
  formData.append('model', 'gpt-4o-mini-transcribe');
  formData.append('language', 'he');

  const openAiRes = await fetch('https://api.openai.com/v1/audio/transcriptions', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${OPENAI_API_KEY}` },
    body: formData
  });
  const openAiData = await openAiRes.json();
  return openAiData.text || "";
}

async function compileInventoryReply(userPhoneNumber, processedText) {
  if (!userStates.has(userPhoneNumber)) {
    userStates.set(userPhoneNumber, createEmptyInventoryState());
  }
  const currentState = userStates.get(userPhoneNumber);

  const geminiResponse = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=${GEMINI_API_KEY}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      contents: [{
        role: 'user',
        parts: [
          { text: INVENTORY_SYSTEM_PROMPT },
          { text: `Current state: ${JSON.stringify(currentState)}` },
          { text: `Incoming employee update: "${processedText}"` }
        ]
      }],
      generationConfig: { responseMimeType: "application/json" }
    })
  });

  const geminiData = await geminiResponse.json();
  const geminiJsonText = geminiData?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!geminiJsonText) {
    throw new Error('Gemini did not return an inventory JSON payload.');
  }

  const parsedResult = parseModelJson(geminiJsonText);
  const updatedState = {
    ...createEmptyInventoryState(),
    ...(parsedResult.updated_state || {})
  };
  userStates.set(userPhoneNumber, updatedState);
  console.log(`[STATE LOG] Updated inventory record tracking for ${userPhoneNumber}:`, updatedState);
  return { ...parsedResult, updated_state: updatedState };
}

async function sendMetaReadReceipt(phoneNumberId, messageId) {
  if (!WHATSAPP_ACCESS_TOKEN || !phoneNumberId) return;
  try {
    await fetch(`https://graph.facebook.com/v21.0/${phoneNumberId}/messages`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${WHATSAPP_ACCESS_TOKEN}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        status: "read",
        message_id: messageId
      })
    });
    console.log(`[WHATSAPP LOG] Sent native read receipt for message ID: ${messageId}`);
  } catch (receiptError) {
    console.error('Failed to send WhatsApp read receipt status update:', receiptError);
  }
}

async function sendWhatsAppTextReply(phoneNumberId, userPhoneNumber, body) {
  if (!WHATSAPP_ACCESS_TOKEN || !phoneNumberId || !body) return;
  await fetch(`https://graph.facebook.com/v21.0/${phoneNumberId}/messages`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${WHATSAPP_ACCESS_TOKEN}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: userPhoneNumber,
      type: "text",
      text: { preview_url: false, body }
    })
  });
  console.log(`[WORKER] Dispatched data-validation message to dealership device ${userPhoneNumber}`);
}

function isLocalBridgeRequest(req) {
  return req.headers['x-pirsumoto-local-bridge'] === 'android' ||
    req.body?.source === 'pirsumoto_android_whatsapp_bridge';
}

function requestJsonBody(req) {
  if (req.body && typeof req.body === 'object' && !Buffer.isBuffer(req.body)) {
    return req.body;
  }

  const raw = Buffer.isBuffer(req.rawBody)
    ? req.rawBody.toString('utf8')
    : (req.body || req.rawBody || '');
  if (!raw) return {};
  return JSON.parse(raw);
}

async function handleLocalBridgeRequest(req, res) {
  if (LOCAL_BRIDGE_TOKEN && req.headers['x-pirsumoto-device-token'] !== LOCAL_BRIDGE_TOKEN) {
    console.warn('Dropped local WhatsApp bridge payload: token mismatch.');
    return res.status(401).json({ ok: false, error: 'Unauthorized local bridge token' });
  }

  try {
    const body = requestJsonBody(req);
    const userPhoneNumber = body.senderId || body.senderName || body.conversationTitle || 'android-local-whatsapp';
    const messageId = body.messageId || `${userPhoneNumber}:${body.timestamp || Date.now()}:${body.text || body.audioFileName || ''}`;

    if (!rememberMessageId(messageId)) {
      console.log(`[DEDUPLICATION] Intercepted duplicate local bridge ID: ${messageId}. Dropping payload.`);
      return res.status(200).json({ ok: true, duplicate: true });
    }

    let processedText = (body.text || body.transcript || '').toString();

    if (!processedText.trim() && body.type === 'audio' && body.audioBase64) {
      const audioBuffer = Buffer.from(body.audioBase64, 'base64');
      processedText = await transcribeAudioBuffer(
        audioBuffer,
        body.audioMimeType || 'audio/ogg',
        body.audioFileName || 'audio.ogg'
      );
      console.log(`[LOCAL BRIDGE] Transcription: "${processedText}"`);
    }

    if (!processedText.trim()) {
      return res.status(200).json({ ok: true, reply_hebrew: null, reason: 'empty_message' });
    }

    const parsedResult = await compileInventoryReply(userPhoneNumber, processedText);
    return res.status(200).json({
      ok: true,
      reply_hebrew: parsedResult.reply_hebrew,
      updated_state: parsedResult.updated_state
    });
  } catch (error) {
    console.error('Local WhatsApp bridge worker crashed:', error);
    return res.status(500).json({ ok: false, error: 'LOCAL_BRIDGE_FAULT' });
  }
}

functions.http('whatsappGatekeeper', async (req, res) => {

  // ==========================================
  // 1. HANDSHAKE VERIFICATION LOOP (GET)
  // ==========================================
  if (req.method === 'GET') {
    const mode = req.query['hub.mode'];
    const token = req.query['hub.verify_token'];
    const challenge = req.query['hub.challenge'];

    if (mode === 'subscribe' && token === VERIFY_TOKEN) {
      console.log('Webhook successfully verified by Meta Handshake.');
      return res.status(200).send(challenge);
    }
    console.warn('Unauthorized or mismatched validation token handshake rejected.');
    return res.status(403).send('Forbidden');
  }

  // ==========================================
  // 2. INCOMING MESSAGE FIREHOSE (POST)
  // ==========================================
  if (req.method === 'POST') {
    if (isLocalBridgeRequest(req)) {
      return handleLocalBridgeRequest(req, res);
    }

    const signature = req.headers['x-hub-signature-256'];

    if (!signature) {
      console.warn('Dropped message payload: Missing X-Hub-Signature-256 header.');
      return res.status(401).send('Missing Signature');
    }

    let verifyPayload;
    if (Buffer.isBuffer(req.rawBody)) {
      verifyPayload = req.rawBody;
    } else if (typeof req.body === 'object') {
      verifyPayload = JSON.stringify(req.body);
    } else {
      verifyPayload = req.rawBody || '';
    }

    const expectedSignature = 'sha256=' + crypto
      .createHmac('sha256', APP_SECRET)
      .update(verifyPayload)
      .digest('hex');

    if (signature !== expectedSignature) {
      console.error('Dropped message payload: Cryptographic signature mismatch verification failed.');
      return res.status(401).send('Unauthorized Signature');
    }

    try {
      const entry = req.body?.entry?.[0];
      const change = entry?.changes?.[0];
      const value = change?.value;

      if (value?.messages && value.messages.length > 0) {
        const incomingMessage = value.messages[0];
        const userPhoneNumber = incomingMessage.from;
        const messageId = incomingMessage.id;
        const phoneNumberId = value.metadata?.phone_number_id || value.metadata?.phone_id;

        if (!rememberMessageId(messageId)) {
          console.log(`[DEDUPLICATION] Intercepted duplicate webhook ID: ${messageId}. Dropping payload.`);
          return res.status(200).send('EVENT_RECEIVED');
        }

        if (incomingMessage.type === 'text' || incomingMessage.type === 'audio') {
          await sendMetaReadReceipt(phoneNumberId, messageId);

          // ==========================================
          // ASYNCHRONOUS BACKGROUND PROCESSING THREAD
          // ==========================================
          (async () => {
            try {
              let processedText = "";

              // Track 1: Text
              if (incomingMessage.type === 'text') {
                processedText = incomingMessage.text.body;
              }
              else if (incomingMessage.type === 'audio') {
                console.log(`[WORKER] Downloading voice note ID: ${incomingMessage.audio.id}`);
                const mediaRes = await fetch(`https://graph.facebook.com/v21.0/${incomingMessage.audio.id}`, {
                  headers: { 'Authorization': `Bearer ${WHATSAPP_ACCESS_TOKEN}` }
                });
                const mediaMetadata = await mediaRes.json();

                if (mediaMetadata?.url) {
                  const audioBinaryRes = await fetch(mediaMetadata.url, {
                    headers: { 'Authorization': `Bearer ${WHATSAPP_ACCESS_TOKEN}` }
                  });
                  const audioBuffer = Buffer.from(await audioBinaryRes.arrayBuffer());
                  processedText = await transcribeAudioBuffer(
                    audioBuffer,
                    incomingMessage.audio.mime_type || 'audio/ogg',
                    'audio.ogg'
                  );
                  console.log(`[WORKER] Transcription: "${processedText}"`);
                }
              }

              if (!processedText.trim()) return;
              const parsedResult = await compileInventoryReply(userPhoneNumber, processedText);

              // Enforce artificial execution sleep to bypass algorithmic speed thresholds
              await new Promise(resolve => setTimeout(resolve, 4000));
              await sendWhatsAppTextReply(phoneNumberId, userPhoneNumber, parsedResult.reply_hebrew);
            } catch (bgError) {
              console.error('Background worker crashed:', bgError);
            }
          })();
        }
      }

      // Stream the message data into your Pub/Sub pipeline as before
      const dataBuffer = Buffer.from(JSON.stringify(req.body));
      await pubsub.topic(TOPIC_NAME).publishMessage({ data: dataBuffer });

      return res.status(200).send('EVENT_RECEIVED');
    } catch (error) {
      console.error('Failed to process incoming payload or dispatch to Pub/Sub:', error);
      return res.status(200).send('INTERNAL_QUEUE_FAULT');
    }
  }

  res.status(405).send('Method Not Allowed');
});
