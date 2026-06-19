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

// SECURITY WARNING: Move these keys to your Cloud Environment Variables in production!
const GEMINI_API_KEY = process.env.GEMINI_API_KEY || 'AQ.Ab8RN6I0DFFHKEIB6lMtXqVDYm_7OGg9r9-norHBsXGY-LbruA';
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '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';

// Cache to prevent duplicate webhook processing across rapid delivery attempts
const processedMessageIds = new Set();
// Stateful memory tracker to preserve chat listing history across turn boundaries
const userStates = new Map();

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

        // Deduplication Guard: If Meta retries a lagging webhook, drop duplicates early
        if (processedMessageIds.has(messageId)) {
          console.log(`[DEDUPLICATION] Intercepted duplicate webhook ID: ${messageId}. Dropping payload.`);
          return res.status(200).send('EVENT_RECEIVED');
        }
        processedMessageIds.add(messageId);

        // Prevent cache memory leak over time
        if (processedMessageIds.size > 5000) {
          const firstElement = processedMessageIds.values().next().value;
          processedMessageIds.delete(firstElement);
        }

        if (incomingMessage.type === 'text' || incomingMessage.type === 'audio') {

          // ==========================================
          // MODIFIED RESPONSE 1: Native Read Receipt
          // ==========================================
          if (WHATSAPP_ACCESS_TOKEN && phoneNumberId) {
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
              // Track 2: Audio Transcription via OpenAI
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

                  const formData = new FormData();
                  const audioBlob = new Blob([audioBuffer], { type: incomingMessage.audio.mime_type || 'audio/ogg' });
                  formData.append('file', audioBlob, 'audio.ogg');
                  formData.append('model', 'gpt-4o-mini-transcribe');
                  formData.append('language', 'he');

                  const openAiRes = await fetch('https://api.openai.com/v1/audio/transcriptions', {
                    method: 'POST',
                    headers: { 'Authorization': `Bearer ${OPENAI_API_KEY}` },
                    body: formData
                  });
                  const openAiData = await openAiRes.json();
                  processedText = openAiData.text || "";
                  console.log(`[WORKER] Transcription: "${processedText}"`);
                }
              }

              if (!processedText.trim()) return;

              // Initialize state memory
              if (!userStates.has(userPhoneNumber)) {
                userStates.set(userPhoneNumber, {
                  license_plate: null, test_month: null, test_year: null, hand: null,
                  current_ownership: null, previous_ownership: null, km: null, price: null,
                  description: null, gear_type: null
                });
              }
              const currentState = userStates.get(userPhoneNumber);

              // ==========================================
              // GEMINI B2B INVENTORY DATA COMPILATION
              // ==========================================
              const systemPrompt = `
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

              const geminiResponse = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=${GEMINI_API_KEY}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                  contents: [{
                    role: 'user',
                    parts: [
                      { text: systemPrompt },
                      { text: `Current state: ${JSON.stringify(currentState)}` },
                      { text: `Incoming employee update: "${processedText}"` }
                    ]
                  }],
                  generationConfig: { responseMimeType: "application/json" }
                })
              });

              const geminiData = await geminiResponse.json();
              const geminiJsonText = geminiData?.candidates?.[0]?.content?.parts?.[0]?.text;

              if (geminiJsonText) {
                const parsedResult = JSON.parse(geminiJsonText);
                userStates.set(userPhoneNumber, parsedResult.updated_state);
                console.log(`[STATE LOG] Updated inventory record tracking for ${userPhoneNumber}:`, parsedResult.updated_state);

                // ==========================================
                // MODIFIED RESPONSE 2: Jitter Processing Delay
                // ==========================================
                // Enforce artificial execution sleep to bypass algorithmic speed thresholds
                await new Promise(resolve => setTimeout(resolve, 4000));

                if (WHATSAPP_ACCESS_TOKEN && phoneNumberId) {
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
                      text: { preview_url: false, body: parsedResult.reply_hebrew }
                    })
                  });
                  console.log(`[WORKER] Dispatched data-validation message to dealership device ${userPhoneNumber}`);
                }
              }
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