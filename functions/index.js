const functions = require('@google-cloud/functions-framework');
const { onRequest } = require('firebase-functions/v2/https');
const { PubSub } = require('@google-cloud/pubsub');
const crypto = require('crypto');
const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp();
}
const db = admin.firestore();

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

async function handleWhatsappGatekeeper(req, res) {

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
}

// ============================================================================
// REMOTE CONTROL SECURE VALIDATION & WHISPER BACKEND PROXY
// ============================================================================

const DEFAULT_SYSTEM_PROMPT = `
אתה עוזר שיחה חכם ומומחה לחילוץ מידע עבור צ׳אטבוט WhatsApp לפרסום רכב ביד2 ובפייסבוק מרקטפלייס בישראל.

תפקידך הכפול:
1. זיהוי כוונת המשתמש (intent) וחילוץ נתונים חדשים או מתוקנים עבור הרכב (extracted_fields) בהתאם לכללים המחמירים של יד2.
2. ניסוח הודעת מענה קצרה, אדיבה ועוזרת בעברית (assistant_reply) המתאימה לוואטסאפ, המנחה את המשתמש במדויק לעבר השלמת פרטי הרכב ופרסומו.

========================
זיהוי כוונות (intent)
====================
- "republish_last": המשתמש מבקש לפרסם שוב, להמשיך מהיכן שהפסיק/עצר, לשחזר נתוני רכב קודם, או לעשות שימוש בנתוני הרכב האחרון/הקודם שלו.
- "update_details": המשתמש מספק פרטי רכב (קילומטראז', מחיר, צבע וכו') או מעדכן פרט קודם.
- "greeting_or_help": המשתמש אומר שלום, מברך, שואל איך זה עובד, או מבקש עזרה כללית מבלי למסור עדיין מספר רישוי או פרטים.
- "cancel": המשתמש מבקש לבטל את התהליך.
- "chat": הודעה כללית אחרת.

========================
כללי מענה בשיחה (assistant_reply)
================================
ההודעה תהיה תמיד בעברית טבעית, תמציתית, מקצועית ומותאמת לווצאפ:
1. כאשר intent הוא "republish_last":
   - אם ב-last_saved_vehicle קיימים פרטי רכב: אשר שמצאת את הרכב (ציין יצרן, דגם, שנת ייצור ומספר רישוי). אם המשתמש ביקש לשנות פרט (למשל מחיר או ק"מ), אשר את השינוי. בקש תמונות של הרכב כדי להתחיל בפרסום, או שאל האם כל הנתונים מדויקים להמשך.
   - אם ב-last_saved_vehicle אין פרטי רכב: הסבר בנימוס שלא נמצאו פרטי רכב שמורים קודמים, ובקש לשלוח מספר רישוי בן 7 או 8 ספרות כדי להתחיל.
2. כאשר intent הוא "greeting_or_help" (ולא פעיל סשן):
   - הצג את עצמך בתור הבוט של פירסומוטו, הסבר בקצרה שאתה מסייע לפרסם את הרכב ביד2 ובפייסבוק, ובקש מהמשתמש לשלוח את מספר הרישוי של הרכב (7 או 8 ספרות) או להקליט הודעה קולית כדי להתחיל.
3. כאשר intent הוא "update_details":
   - אשר בקצרה את הנתונים שנקלטו, והצג את כל השדות החסרים יחד מתוך missing_fields_in_requested_order ברשימה מרוכזת אחת (מופרדים בנקודות או שורות), כך שהמשתמש יוכל למלא ולספק את כולם יחד. לעולם אל תשאל שדה אחד בודד בכל פעם כאשר ישנם מספר שדות חסרים.
   - אם כל השדות הושלמו, הודע שהפרטים מוכנים, ובקש להעלות תמונות או ללחוץ על "פרסם עכשיו" כדי להתחיל בפרסום ביד2 ובפייסבוק.
4. השאר את התשובות ממוקדות ונעימות בווצאפ - ללא טקסטים ארוכים מדי.

========================
כללי OUTPUT
===========

החזר אובייקט JSON אחד בלבד במבנה הבא:
{
  "intent": "update_details" | "republish_last" | "greeting_or_help" | "cancel" | "chat",
  "extracted_fields": {
     // שדות שחולצו מההודעה בלבד
  },
  "assistant_reply": "הודעת מענה לווצאפ בעברית"
}

כללים נוספים לחילוץ:
- החזר ב-extracted_fields רק שדות שהמידע שלהם ניתן להסיק באופן סביר מההודעה הנוכחית.
- אל תחזיר שדות שלא הופיעו בהודעה הנוכחית, גם אם הם מופיעים ב-current_verified_fields או בהיסטוריה.
- אל תעתיק ערכים קיימים רק משום שהם קיימים בהקשר.
- אל תנחש.
- אל תשלים ערכים חסרים באמצעות ברירת מחדל.
- אם המשתמש מתקן ערך קודם, החזר את הערך החדש ב-extracted_fields.
- אם אין מידע חדש שניתן לשייך בביטחון לאחד השדות המותרים, החזר extracted_fields ריק: {}.
- אם המשתמש מסר מספר פרטים באותה הודעה, החזר את כולם באותו JSON.
- לעולם אל תחזיר license_plate או license בתוך extracted_fields. זיהוי לוחית הרישוי מתבצע מחוץ למודל.

========================
השדות המותרים
=============

km
price
hand
maker
model
year
color
month
test_month
test_year
current_ownership
previous_ownership
vehicle_condition
gear_type
description
fuel_type

אין להחזיר שום מפתח אחר.
`;

const DEFAULT_ALLOWED_COLORS = [
  'אדום', 'כחול', 'צהוב', 'אפור', 'לבן', 'שחור', 'סגול', 'ורוד', 'חום', 'ירוק', 'כתום'
];

function normalizeHebrewDigits(text) {
  if (!text) return '';
  let s = text.trim();
  const wordToDigit = {
    'אפס': '0', 'אחת': '1', 'אחד': '1', 'שתיים': '2', 'שניים': '2', 'שתים': '2', 'שנים': '2',
    'שלוש': '3', 'שלושה': '3', 'ארבע': '4', 'ארבעה': '4', 'חמש': '5', 'חמישה': '5',
    'שש': '6', 'שישה': '6', 'שבע': '7', 'שבעה': '7', 'שמונה': '8', 'שמונה עשרה': '18',
    'תשע': '9', 'תשעה': '9', 'עשר': '10', 'עשרה': '10', 'עשרים': '20', 'שלושים': '30',
    'ארבעים': '40', 'חמישים': '50', 'שישים': '60', 'שבעים': '70', 'שמונים': '80',
    'תשעים': '90', 'מאה': '100'
  };
  for (const [k, v] of Object.entries(wordToDigit)) {
    s = s.replace(new RegExp(`(?<=^|[\\s,.\\-!?])${k}(?=$|[\\s,.\\-!?])`, 'gi'), v);
  }
  return s;
}

function normalizeHand(h) {
  if (h === 'ראשונה' || h === '1') return '1';
  if (h === 'שנייה' || h === 'שניה' || h === '2') return '2';
  if (h === 'שלישית' || h === '3') return '3';
  if (h === 'רביעית' || h === '4') return '4';
  if (h === 'חמישית' || h === '5') return '5';
  return h;
}

function sanitizeFields(rawFields) {
  const result = {};
  if (!rawFields || typeof rawFields !== 'object') return result;

  for (let [rawKey, rawVal] of Object.entries(rawFields)) {
    let key = rawKey.trim();
    if (key === 'vehicleCondition') key = 'vehicle_condition';
    if (key === 'ownership') key = 'current_ownership';
    if (key === 'gear') key = 'gear_type';
    if (rawVal == null) continue;

    let val = String(rawVal).trim();
    if (!val || val.toLowerCase() === 'null') continue;

    if (key === 'km' || key === 'price') {
      const digits = val.replace(/\D/g, '');
      if (parseInt(digits, 10) > 0) result[key] = digits;
    } else if (key === 'hand') {
      result[key] = normalizeHand(val);
    } else {
      result[key] = val;
    }
  }
  return result;
}

function getMissingFields(state) {
  const missing = [];
  if (!state.license_plate) missing.push('license_plate');
  if (!state.km) missing.push('km');
  if (!state.price) missing.push('price');
  if (!state.hand) missing.push('hand');
  if (!state.color) missing.push('color');
  return missing;
}

function validateValues(state) {
  const errors = [];
  if (state.km) {
    const km = parseInt(state.km, 10);
    if (isNaN(km) || km < 0 || km > 1500000) errors.push('קילומטראז לא תקין');
  }
  if (state.price) {
    const price = parseInt(state.price, 10);
    if (isNaN(price) || price <= 0) errors.push('מחיר לא תקין');
  }
  return errors;
}

function composeFallbackHebrewReply(state, missingKeys, validationErrors, isFirstTurn, imageCount) {
  const plate = state.license_plate || '';
  if (!plate) {
    return 'שלום! 👋 אני הבוט של פירסומוטו לפרסום רכב.\nכדי להתחיל, שלח מספר רישוי ישראלי (7 או 8 ספרות), או הקלט הודעה קולית עם פרטי הרכב.';
  }

  const lines = [];
  if (isFirstTurn) {
    if (state.maker) {
      lines.push(`🚗 זיהיתי את הרכב: ${state.maker} ${state.model || ''} שנת ${state.year || ''} (רישוי ${plate}).`);
    } else {
      lines.push(`🚗 מספר רישוי נקלט: ${plate}.`);
    }
  }

  if (validationErrors.length > 0) {
    lines.push('\n⚠️ שים לב:');
    for (const err of validationErrors) {
      lines.push(`• ${err}`);
    }
  }

  if (missingKeys.length > 0) {
    lines.push('\nכדי להשלים את הפרסום, אנא ציין:');
    for (const key of missingKeys) {
      if (key === 'km') lines.push('• קילומטראז\' (ק"מ)');
      else if (key === 'price') lines.push('• מחיר מבוקש בש"ח');
      else if (key === 'hand') lines.push('• יד (למשל: יד 1, יד 2)');
      else if (key === 'color') lines.push('• צבע הרכב');
    }
  } else {
    lines.push('\n✅ כל פרטי הרכב מלאים ומאומתים!');
    if (imageCount === 0) {
      lines.push('📷 אנא צרף לפחות תמונה אחת של הרכב כדי להתחיל בפרסום.');
    } else {
      lines.push(`📷 צורפו ${imageCount} תמונות. לחץ על "פרסם עכשיו" להתחלת הפרסום ביד2.`);
    }
  }
  return lines.join('\n');
}

async function fetchGovIlData(plate) {
  try {
    const url = `https://data.gov.il/api/3/action/datastore_search?resource_id=053cea08-09bc-40ec-8f7a-156f0677aff3&q=${encodeURIComponent(plate)}`;
    const res = await fetch(url);
    if (!res.ok) return null;
    const json = await res.json();
    const records = json?.result?.records;
    if (records && records.length > 0) {
      const rec = records[0];
      return {
        maker: rec.tozeret_nm || rec.tozeret_cd || '',
        model: rec.kinuy_mishari || rec.degem_nm || '',
        year: rec.shnat_yitzur ? String(rec.shnat_yitzur) : '',
        color: rec.tzeva_rechev || '',
        fuelType: rec.sug_delek_nm || 'בנזין',
        ownership: rec.baalut || 'פרטית',
        registrationMonth: rec.moed_aliya_lakvish ? String(rec.moed_aliya_lakvish) : '',
        gear_type: (rec.gear_type || '').includes('ידני') ? 'ידני' : 'הילוכים אוטומטיים',
        testExpiry: rec.tokef_dt || ''
      };
    }
  } catch (e) {
    console.error('Gov.il lookup error:', e);
  }
  return null;
}

async function handleRemoteValidation(req, res) {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  if (req.method === 'OPTIONS') {
    return res.status(204).send('');
  }

  try {
    const body = requestJsonBody(req);
    const action = body.action || 'process_turn';

    // 1. Audio Transcription (Whisper)
    if (action === 'transcribe_audio') {
      const audioBase64 = body.audioBase64;
      if (!audioBase64) {
        return res.status(400).json({ ok: false, error: 'missing_audioBase64' });
      }
      const audioBuffer = Buffer.from(audioBase64, 'base64');
      const text = await transcribeAudioBuffer(
        audioBuffer,
        body.mimeType || 'audio/m4a',
        body.fileName || 'audio.m4a'
      );
      const normalized = normalizeHebrewDigits(text);
      return res.status(200).json({ ok: true, text: normalized });
    }

    // 2. License Plate Extraction
    if (action === 'extract_license_plate') {
      const historyText = body.chatHistoryText || '';
      const prompt = `You are an AI assistant. Find the 7 or 8 digit Israeli license plate number mentioned in this chat history.\nOutput ONLY the 7 or 8 digits, or exactly "NONE".\n\nChat history:\n${historyText}`;

      const openAiRes = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${OPENAI_API_KEY}`
        },
        body: JSON.stringify({
          model: 'gpt-4o-mini',
          messages: [{ role: 'user', content: prompt }]
        })
      });
      const data = await openAiRes.json();
      const content = data?.choices?.[0]?.message?.content?.trim() || '';
      if (content && content !== 'NONE') {
        const digits = content.replace(/\D/g, '');
        if (digits.length === 7 || digits.length === 8) {
          return res.status(200).json({ ok: true, licensePlate: digits });
        }
      }
      return res.status(200).json({ ok: true, licensePlate: null });
    }

    // 3. Process Chat Turn
    if (action === 'process_turn') {
      const incomingText = (body.incomingText || '').toString().trim();
      const currentVehicleData = body.currentVehicleData || {};
      const chatHistory = body.chatHistory || [];
      const imageCount = parseInt(body.currentImageCount || '0', 10);

      // Fetch dynamic system prompt & rules from Firestore (Server Admin SDK)
      let systemPrompt = body.systemPrompt || DEFAULT_SYSTEM_PROMPT;
      let allowedColors = DEFAULT_ALLOWED_COLORS;
      let valDoc = null;
      try {
        valDoc = await db.collection('agent_config').doc('whatsapp_validation').get();
        if (valDoc.exists) {
          const valData = valDoc.data() || {};
          const basePrompt = valData.systemPrompt || (body.systemPrompt ? body.systemPrompt : DEFAULT_SYSTEM_PROMPT);
          const rulesMd = valData.rules_md ||
            valData.rulesMd ||
            (typeof valData.rules === 'string' ? valData.rules : (valData.rules && valData.rules.rules_md));
          const generalRules = valData.generalRules || (valData.rules && valData.rules.generalRules);

          let combined = basePrompt;
          if (rulesMd && typeof rulesMd === 'string' && rulesMd.trim()) {
            combined += `\n\n========================\nהוראות סוכן וכללים (AGENT RULES)\n================================\n<agent_rules>\n${rulesMd.trim()}\n</agent_rules>`;
          }
          if (generalRules) {
            let list = [];
            if (Array.isArray(generalRules)) {
              list = generalRules.map(r => String(r).trim()).filter(Boolean);
            } else if (typeof generalRules === 'string') {
              list = generalRules.split('\n').map(r => r.trim()).filter(Boolean);
            }
            if (list.length > 0) {
              combined += `\n\n========================\nכללים כלליים נוספים (GENERAL RULES)\n==================================\n` + list.map(r => `- ${r}`).join('\n');
            }
          }
          systemPrompt = combined;

          if (valData.allowedColors && Array.isArray(valData.allowedColors) && valData.allowedColors.length > 0) {
            allowedColors = valData.allowedColors;
          }
        }
      } catch (e) {
        console.warn('Could not read agent_config from Firestore, using default system prompt:', e);
      }

      // Enforce batching on systemPrompt to eliminate any cached 1-by-1 phrasing
      systemPrompt = systemPrompt.replace(
        /והנחה את המשתמש לספק את השדה הבא שחסר מתוך missing_fields_in_requested_order/g,
        'והצג את כל השדות החסרים יחד מתוך missing_fields_in_requested_order ברשימה מרוכזת אחת (מופרדים בנקודות או שורות) כדי שהמשתמש יוכל לספק את כולם יחד'
      );

      systemPrompt += `\n\n========================\nכלל מחייב להצגת שדות חסרים (BATCHING MISSING FIELDS)\n===================================================\nכאשר חסרים פרטים ברכב (missing_fields_in_requested_order מכיל יותר משדה אחד):\nחובה תמיד להציג למשתמש את כל השדות החסרים יחד ברשימה מרוכזת אחת מופרדת בשורות או בנקודות (למשל: קילומטראז', מחיר, יד, צבע), כדי שהמשתמש יוכל למלא ולספק את כולם יחד בהודעה אחת.\nלעולם אל תבקש רק שדה בודד אחד בכל פעם!`;

      const state = { ...currentVehicleData };
      const plateMatch = incomingText.match(/\b\d{7,8}\b/);
      const rawPlate = plateMatch ? plateMatch[0] : null;
      let isFirstTurn = false;

      if (rawPlate && !state.license_plate) {
        state.license_plate = rawPlate;
        state.license = rawPlate;
        isFirstTurn = true;
        const govData = await fetchGovIlData(rawPlate);
        if (govData) {
          state.maker = govData.maker || '';
          state.model = govData.model || '';
          state.year = govData.year || '';
          state.color = govData.color || '';
          state.fuel_type = govData.fuelType || '';
          state.current_ownership = govData.ownership || 'פרטית';
          state.previous_ownership = govData.ownership || 'פרטית';
          state.month = govData.registrationMonth || '';
          state.test_month = govData.registrationMonth || '';
          state.gear_type = govData.gear_type || 'הילוכים אוטומטיים';
        }
      }

      const hasActiveSession = Boolean(state.license_plate);
      if (hasActiveSession && !state.vehicle_condition) {
        state.vehicle_condition = 'טוב';
      }

      const missingBeforeTurn = hasActiveSession ? getMissingFields(state) : ['license_plate'];
      const errorsBeforeTurn = hasActiveSession ? validateValues(state) : [];

      // Call OpenAI securely on server
      const requestData = {
        current_message: incomingText,
        has_active_session: hasActiveSession,
        current_verified_fields: state,
        missing_fields_in_requested_order: missingBeforeTurn,
        field_errors: errorsBeforeTurn,
        last_saved_vehicle: {},
        recent_session_history: chatHistory.slice(-10),
        allowed_yad2_colors: allowedColors
      };

      // Model selection (defaulting to gpt-5.6-luna with fallback)
      // Model selection & API key (with Firestore override support)
      const activeApiKey = (valDoc && valDoc.exists ? (valDoc.data()?.openAiApiKey || valDoc.data()?.apiKey) : null) || OPENAI_API_KEY;
      const targetModel = body.aiModel || (valDoc && valDoc.exists ? valDoc.data()?.aiModel : null) || 'gpt-5.6-luna';

      let aiReply = null;
      let extractedFields = {};

      try {
        const payload = {
          model: targetModel,
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: JSON.stringify(requestData) }
          ]
        };
        if (targetModel === 'gpt-5.6-luna') {
          payload.max_completion_tokens = 350;
          payload.reasoning_effort = 'low';
          payload.temperature = 0.2;
        }

        let llmRes = await fetch('https://api.openai.com/v1/chat/completions', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${activeApiKey}`
          },
          body: JSON.stringify(payload)
        });

        // Fallback to gpt-4o-mini if primary model returns an error
        if (!llmRes.ok && targetModel !== 'gpt-4o-mini') {
          console.warn(`Primary model ${targetModel} returned ${llmRes.status}, falling back to gpt-4o-mini`);
          llmRes = await fetch('https://api.openai.com/v1/chat/completions', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'Authorization': `Bearer ${activeApiKey}`
            },
            body: JSON.stringify({
              model: 'gpt-4o-mini',
              messages: [
                { role: 'system', content: systemPrompt },
                { role: 'user', content: JSON.stringify(requestData) }
              ]
            })
          });
        }

        if (llmRes.ok) {
          const llmData = await llmRes.json();
          const cachedTokens = llmData.usage?.prompt_tokens_details?.cached_tokens || 0;
          const totalPromptTokens = llmData.usage?.prompt_tokens || 0;
          console.log(`[LLM CACHE STATS] Prompt tokens: ${totalPromptTokens}, Cached prefix tokens: ${cachedTokens} (${cachedTokens > 0 ? 'CACHE HIT' : 'CACHE MISS'})`);

          const content = llmData?.choices?.[0]?.message?.content?.trim() || '';
          const jsonMatch = content.match(/\{[\s\S]*\}/);
          if (jsonMatch) {
            const parsed = JSON.parse(jsonMatch[0]);
            aiReply = parsed.assistant_reply || null;
            if (parsed.extracted_fields) {
              extractedFields = sanitizeFields(parsed.extracted_fields);
            }
          }
        }
      } catch (llmErr) {
        console.error('Server LLM call error:', llmErr);
      }

      // Merge extracted fields
      for (const [k, v] of Object.entries(extractedFields)) {
        if (v) state[k] = v;
      }

      // Fallback heuristics for numbers & positional sequential inputs (as per rules_md)
      if (hasActiveSession) {
        // 1. Check positional multi-line / comma input if multiple missing fields exist
        if (missingBeforeTurn.length > 0) {
          const parts = incomingText
            .split(/[\n,;/]+/)
            .map(p => p.trim())
            .filter(p => p.length > 0);

          if (parts.length > 1 || (parts.length === 1 && missingBeforeTurn.length === 1)) {
            for (let i = 0; i < parts.length && i < missingBeforeTurn.length; i++) {
              const field = missingBeforeTurn[i];
              const val = parts[i];
              if (!state[field]) {
                if (field === 'km' || field === 'price') {
                  const digits = val.replace(/\D/g, '');
                  if (parseInt(digits, 10) > 0) {
                    let num = digits;
                    if (val.includes('אלף') && parseInt(num, 10) < 1000) {
                      num = String(parseInt(num, 10) * 1000);
                    }
                    state[field] = num;
                  }
                } else if (field === 'hand') {
                  state[field] = normalizeHand(val);
                } else if (field === 'color') {
                  state[field] = val;
                } else if (field === 'vehicle_condition') {
                  state[field] = val;
                }
              }
            }
          }
        }

        // 2. Individual regex patterns for explicit labels
        if (!state.km) {
          const kmMatch = incomingText.match(/\b(\d{1,3}(?:,\d{3})+|\d{4,6})\s*(?:ק"?מ|קילומטר)?\b/);
          if (kmMatch && kmMatch[1] !== state.license_plate) {
            state.km = kmMatch[1].replace(/,/g, '');
          }
        }
        if (!state.price) {
          const priceMatch = incomingText.match(/\b(?:מחיר|ב-?|סך)\s*(\d{2,6})\b|\b(\d{2,6})\s*(?:ש"ח|שח|שקל|אלף)\b/);
          if (priceMatch) {
            let p = priceMatch[1] || priceMatch[2];
            if (incomingText.includes('אלף') && parseInt(p, 10) < 1000) {
              p = String(parseInt(p, 10) * 1000);
            }
            state.price = p;
          }
        }
        if (!state.hand) {
          const handMatch = incomingText.match(/\bיד\s*(\d+|ראשונה|שנייה|שניה|שלישית|רביעית)\b/);
          if (handMatch) {
            state.hand = normalizeHand(handMatch[1]);
          }
        }
      }

      const missing = hasActiveSession ? getMissingFields(state) : ['license_plate'];
      const errors = hasActiveSession ? validateValues(state) : [];
      const allFilled = hasActiveSession && missing.length === 0 && errors.length === 0;
      const isReady = allFilled && imageCount > 0;

      const finalReply = (aiReply && aiReply.trim())
        ? aiReply.trim()
        : composeFallbackHebrewReply(state, missing, errors, isFirstTurn, imageCount);

      return res.status(200).json({
        ok: true,
        vehicleData: state,
        botReply: finalReply,
        isReadyToPublish: isReady,
        allDataFilled: allFilled,
        isAllFieldsFilled: allFilled,
        missingFields: missing,
        validationErrors: errors
      });
    }

    return res.status(400).json({ ok: false, error: 'unknown_action' });
  } catch (err) {
    console.error('remoteValidation endpoint error:', err);
    return res.status(500).json({ ok: false, error: err.message });
  }
}

// Export for Firebase Functions V2 (me-west1 region)
exports.whatsappGatekeeper = onRequest({ region: 'me-west1', cors: true, timeoutSeconds: 60, memory: '512MiB' }, handleWhatsappGatekeeper);
exports.remoteValidation = onRequest({ region: 'me-west1', cors: true, timeoutSeconds: 60, memory: '512MiB' }, handleRemoteValidation);

// Also register with @google-cloud/functions-framework if started directly
if (typeof functions.http === 'function') {
  try {
    functions.http('whatsappGatekeeper', handleWhatsappGatekeeper);
    functions.http('remoteValidation', handleRemoteValidation);
  } catch (_) { }
}

