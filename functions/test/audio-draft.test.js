const test = require('node:test');
const assert = require('node:assert/strict');
const {normalizeAmount, normalizeIdentifier, normalizeAudioFields, extractAudioDraft, approveAudioDraft} = require('../audio-draft');

test('normalizes Hebrew amounts separately from identifier sequences and names', () => {
  assert.equal(normalizeAmount('מאה עשרים אלף'), '120000');
  assert.equal(normalizeAmount('מאתיים וחמישים אלף'), '250000');
  assert.equal(normalizeAmount('אלפיים עשרים ואחת'), '2021');
  assert.equal(normalizeAmount('120,000'), '120000');
  assert.equal(normalizeIdentifier('אפס חמש שתיים אחת שתיים שלוש ארבע חמש שש שבע'), '0521234567');
  assert.equal(normalizeIdentifier('חמישים ושתיים, מאה ושש עשרה, שלושים ותשע'), '5211639');
  assert.equal(normalizeIdentifier('אפס שבע שמונה שתיים ארבע שלוש שלוש'), '0782433');
  const fields = normalizeAudioFields({contact_name: 'אחד העם', city: 'באר שבע', price: 'מאה עשרים אלף', hand: 'יד שנייה', license_plate: '078-24-33', trim: 'פרימיום', engine_capacity: 'אלף שש מאות', phone: '0521234567', area: 'דרום', govIl: 'true'});
  assert.deepEqual(fields, {license_plate: '0782433', trim: 'פרימיום', price: '120000', hand: '2', engine_capacity: '1600', phone: '0521234567', city: 'באר שבע', area: 'דרום', contact_name: 'אחד העם'});
});

test('extraction preserves the transcript, requires evidence, and requests a strict schema', async () => {
  const text = 'המחיר מאה עשרים אלף, אני מבאר שבע';
  let payload;
  const draft = await extractAudioDraft(text, {apiKey: 'test', request: async (_, options) => {
    payload = JSON.parse(options.body);
    return {ok: true, json: async () => ({choices: [{message: {content: JSON.stringify({
      price: {value: '120000', evidence: 'מאה עשרים אלף'},
      city: {value: 'באר שבע', evidence: 'באר שבע'},
      maker: {value: 'טויוטה', evidence: 'טויוטה'},
      year: {value: '2021', evidence: null},
      license_plate: {value: '9999999', evidence: ''},
    })}}]})};
  }});
  assert.equal(draft.text, text);
  assert.deepEqual(draft.extracted_fields, {price: '120000', city: 'באר שבע'});
  assert.equal(payload.response_format.json_schema.strict, true);
  assert.equal(payload.response_format.json_schema.schema.additionalProperties, false);
  assert.ok(payload.response_format.json_schema.schema.required.includes('contact_name'));
  assert.equal(payload.messages[1].content, text);
});

test('provider failure and invalid JSON fail without silently approving a transcript', async () => {
  await assert.rejects(extractAudioDraft('טקסט', {apiKey: 'test', request: async () => ({ok: false, status: 503})}));
  await assert.rejects(extractAudioDraft('טקסט', {apiKey: 'test', request: async () => ({ok: true, json: async () => ({choices: [{message: {content: 'invalid'}}]})})}));
});

test('approving exact fields looks up only the approved plate and reports conflicts', async () => {
  const calls = [];
  const result = await approveAudioDraft({
    approvedFields: {license_plate: '0782433', maker: 'מאזדה', price: '120000', km: '0', phone: '0521234567', contact_name: 'אחד העם'},
    currentVehicleData: {license_plate: '9999999', maker: 'ישן', price: '9', previous_ownership: 'ליסינג'}, imageCount: 2,
  }, async plate => {calls.push(plate); return {maker: 'טויוטה', model: 'קורולה', fuelType: 'בנזין', ownership: 'פרטית', registrationMonth: '5', estimatedKm: '99999'};});
  assert.deepEqual(calls, ['0782433']);
  assert.equal(result.vehicleData.maker, 'מאזדה');
  assert.equal(result.vehicleData.model, 'קורולה');
  assert.equal(result.vehicleData.price, '120000');
  assert.equal(result.vehicleData.km, '0');
  assert.equal(result.vehicleData.contact_name, 'אחד העם');
  assert.equal(result.vehicleData.previous_ownership, undefined);
  assert.equal(result.vehicleData.govIl, 'true');
  assert.equal(result.isReadyToPublish, false);
  assert.deepEqual(result.governmentConflicts, [{field: 'maker', approved: 'מאזדה', government: 'טויוטה'}]);
});

test('invalid or empty approval cannot perform a government lookup', async () => {
  let lookups = 0;
  for (const approvedFields of [null, [], {}, {license_plate: '123'}, {price: '-5'}, {phone: '123'}, {engine_capacity: 'oops'}, {govIl: 'true'}]) {
    await assert.rejects(approveAudioDraft({approvedFields}, async () => {lookups++;}), {status: 400});
  }
  assert.equal(lookups, 0);
});

test('approval on the same car preserves other fields and does not refetch verified data', async () => {
  const result = await approveAudioDraft({approvedFields: {price: '40000'}, currentVehicleData: {license_plate: '1234567', maker: 'טויוטה', govIl: 'true'}}, async () => {throw new Error('unexpected lookup');});
  assert.equal(result.vehicleData.price, '40000');
  assert.equal(result.vehicleData.maker, 'טויוטה');
  assert.equal(result.vehicleData.license_plate, '1234567');
});

test('a draft without a plate is retained without looking up price or phone as a plate', async () => {
  const result = await approveAudioDraft({approvedFields: {price: '1234567', phone: '0521234567'}}, async () => {throw new Error('unexpected lookup');});
  assert.equal(result.vehicleData.price, '1234567');
  assert.deepEqual(result.missingFields, ['license_plate']);
});

test('a missing government record keeps the approved fields and continues the draft', async () => {
  const result = await approveAudioDraft({approvedFields: {license_plate: '1234567', model: 'קורולה'}}, async () => null);
  assert.equal(result.vehicleData.govIl, 'false');
  assert.equal(result.vehicleData.model, 'קורולה');
});

test('adding the first plate preserves details collected before it', async () => {
  const result = await approveAudioDraft({
    approvedFields: {license_plate: '1234567'},
    currentVehicleData: {price: '120000', phone: '0521234567', contact_name: 'אחד העם'},
  }, async () => ({maker: 'טויוטה'}));
  assert.equal(result.vehicleData.price, '120000');
  assert.equal(result.vehicleData.phone, '0521234567');
  assert.equal(result.vehicleData.contact_name, 'אחד העם');
  assert.equal(result.vehicleData.maker, 'טויוטה');
});

test('controller recognition prioritizes plates without example data and extracts actual returned speech', async () => {
  const {transcribeRecording} = require('../audio-draft');
  const spoken = 'המחיר 45000';
  let argumentsReceived;
  const draft = await transcribeRecording({audioBuffer: Buffer.from('recorded audio'), requirePlate: false}, {
    apiKey: 'test', transcribe: async (...args) => {argumentsReceived = args; return spoken;},
    request: async (_, options) => {
      assert.equal(JSON.parse(options.body).messages[1].content, spoken);
      return {ok: true, json: async () => ({choices: [{message: {content: JSON.stringify({
        price: {value: '45000', evidence: '45000'},
      })}}]})};
    },
  });
  assert.equal(argumentsReceived.length, 5);
  assert.equal(argumentsReceived[3], 'he');
  assert.match(argumentsReceived[4], /העדיפות הראשונה.*מספר הרישוי/);
  assert.match(argumentsReceived[4], /בספרות בלבד/);
  assert.doesNotMatch(argumentsReceived[4], /5211639|45000/);
  assert.equal(draft.text, spoken);
  assert.equal(draft.extracted_fields.price, '45000');
});

test('evidence tolerates transcript punctuation and spacing without losing valid extracted fields', async () => {
  const draft = await extractAudioDraft('המחיר: 120,000. העיר באר  שבע', {apiKey: 'test', request: async () => ({
    ok: true, json: async () => ({choices: [{message: {content: JSON.stringify({
      price: {value: '120000', evidence: '120000'},
      city: {value: 'באר שבע', evidence: 'באר שבע'},
    })}}]}),
  })});
  assert.deepEqual(draft.extracted_fields, {price: '120000', city: 'באר שבע'});
});

test('only the edited confirmed plate drives lookup; remaining audio values merge for inline review', async () => {
  const {mergeRecordedAudio} = require('../audio-draft');
  const plates = [];
  const result = await mergeRecordedAudio({
    recordedFields: {license_plate: '9999999', price: '45000', km: '85000', contact_name: 'אחד העם'},
    confirmedPlate: '0782433', currentVehicleData: {},
  }, async plate => {plates.push(plate); return {maker: 'מאזדה', model: '3', year: '2020', fuelType: 'בנזין'};});
  assert.deepEqual(plates, ['0782433']);
  assert.equal(result.vehicleData.license_plate, '0782433');
  assert.equal(result.vehicleData.maker, 'מאזדה');
  assert.equal(result.vehicleData.price, '45000');
  assert.equal(result.vehicleData.km, '85000');
  assert.equal(result.vehicleData.contact_name, 'אחד העם');
});

test('audio corrections update only supplied fields for the confirmed car', async () => {
  const {mergeRecordedAudio} = require('../audio-draft');
  const result = await mergeRecordedAudio({
    recordedFields: {price: '40000', km: '0'}, confirmedPlate: '1234567',
    currentVehicleData: {license_plate: '1234567', govIl: 'true', maker: 'מאזדה', price: '45000', km: '85000', clean_title: 'כן'},
  }, async () => {throw new Error('already looked up this confirmed car');});
  assert.equal(result.vehicleData.price, '40000');
  assert.equal(result.vehicleData.km, '0');
  assert.equal(result.vehicleData.maker, 'מאזדה');
  assert.equal(result.vehicleData.clean_title, 'כן');
});

test('invalid extracted values remain visible for correction but an invalid confirmed plate cannot be looked up', async () => {
  const {mergeRecordedAudio} = require('../audio-draft');
  let lookups = 0;
  await assert.rejects(mergeRecordedAudio({recordedFields: {price: 'oops'}, confirmedPlate: '123'}, async () => {lookups++;}), {status: 400});
  assert.equal(lookups, 0);
  const result = await mergeRecordedAudio({recordedFields: {price: 'oops'}, confirmedPlate: '1234567'}, async () => null);
  assert.equal(result.vehicleData.price, 'oops');
  assert.ok(result.validationErrors.length);
});

test('joins single digits and two or three digit plate groups without summing them', () => {
  for (const spoken of [
    '5,2,116,39', '5,2,1,1,6,3,9', '521,163,9',
    '5 2 116 39', '521 163 9',
    'חמש שתיים מאה ושש עשרה שלושים ותשע',
    'חמש מאות עשרים ואחת מאה שישים ושלוש תשע',
    'חמישים ושתיים מאה ושש עשרה שלושים ותשע',
  ]) assert.equal(normalizeAudioFields({license_plate: spoken}).license_plate, '5211639', spoken);
  assert.equal(normalizeIdentifier('אפס חמש שתיים מאה ושש עשרה שלושים ותשע'), '05211639');
  assert.equal(normalizeIdentifier('חמש שתיים מספר לא ברור'), 'חמש שתיים מספר לא ברור');
  assert.equal(normalizeIdentifier('5,2,116'), '52116'); // Never pad a short identifier.
});

test('plate extraction converts evidenced spoken groups and still collects other fields', async () => {
  const spokenPlate = 'חמש שתיים מאה ושש עשרה שלושים ותשע';
  const text = `מספר הרכב ${spokenPlate}, המחיר ארבעים אלף`;
  const draft = await extractAudioDraft(text, {apiKey: 'test', request: async (_, options) => {
    const prompt = JSON.parse(options.body).messages[0].content;
    assert.match(prompt, /521,163,9/);
    assert.match(prompt, /7 או 8 ספרות בלבד/);
    return {ok: true, json: async () => ({choices: [{message: {content: JSON.stringify({
      license_plate: {value: spokenPlate, evidence: spokenPlate},
      price: {value: '40000', evidence: 'ארבעים אלף'},
    })}}]})};
  }});
  assert.equal(draft.extracted_fields.license_plate, '5211639');
  assert.equal(draft.extracted_fields.price, '40000');
  assert.deepEqual(draft.validation_errors, []);
});

async function candidateDraft(text, fields) {
  return extractAudioDraft(text, {apiKey: 'test', request: async () => ({
    ok: true, json: async () => ({choices: [{message: {content: JSON.stringify(fields)}}]}),
  })});
}

test('ambiguous evidenced plates are returned as choices without choosing one', async () => {
  const draft = await candidateDraft('מספר רישוי 356 34 678 או 521 163 9', {
    license_plate: {value: '35634678', evidence: '356 34 678'},
    license_plate_candidates: [
      {value: '35634678', evidence: '356 34 678'},
      {value: '5211639', evidence: '521 163 9'},
      {value: '9999999', evidence: '9999999'},
    ],
  });
  assert.deepEqual(draft.license_plate_candidates, ['35634678', '5211639']);
  assert.equal(draft.extracted_fields.license_plate, undefined);
});

test('price cannot become a plate even when it has seven digits', async () => {
  const draft = await candidateDraft('המחיר 1200000. מספר רישוי 356, 34, 678', {
    price: {value: '1200000', evidence: '1200000'},
    license_plate: {value: '1200000', evidence: '1200000'},
    license_plate_candidates: [
      {value: '1200000', evidence: '1200000'},
      {value: '35634678', evidence: '356, 34, 678'},
    ],
  });
  assert.deepEqual(draft.license_plate_candidates, ['35634678']);
  assert.equal(draft.extracted_fields.license_plate, '35634678');
  assert.equal(draft.extracted_fields.price, '1200000');
});

test('candidate must match spoken groups rather than merely quote unrelated speech', async () => {
  const draft = await candidateDraft('מספר רישוי 356 34 678', {
    license_plate_candidates: [{value: '5211639', evidence: '356 34 678'}],
  });
  assert.deepEqual(draft.license_plate_candidates, ['35634678']);
  assert.equal(draft.extracted_fields.license_plate, '35634678');
  assert.equal(normalizeIdentifier('שלוש מאות חמישים ושש שלושים וארבע שש מאות שבעים ושמונה'), '35634678');
});

test('incomplete plate triggers a stronger pass on original audio and retains listing fields', async () => {
  const {transcribeRecording} = require('../audio-draft');
  const audioBuffer = Buffer.from('original recording');
  const calls = [];
  const draft = await transcribeRecording({audioBuffer}, {
    apiKey: 'test', transcribe: async (...args) => {
      calls.push(args);
      return calls.length === 1 ? 'מספר רישוי 35634 מחיר 45000' : 'מספר רישוי 356 34 678';
    },
    request: async (_, options) => {
      const text = JSON.parse(options.body).messages[1].content;
      const recovered = text.includes('678');
      const fields = recovered ? {
        license_plate_candidates: [{value: '35634678', evidence: '356 34 678'}],
      } : {
        license_plate: {value: '35634', evidence: '35634'},
        price: {value: '45000', evidence: '45000'},
      };
      return {ok: true, json: async () => ({choices: [{message: {content: JSON.stringify(fields)}}]})};
    },
  });
  assert.equal(calls.length, 2);
  assert.equal(calls[1][0], audioBuffer);
  assert.equal(calls[1][5], 'gpt-4o-transcribe');
  assert.equal(draft.extracted_fields.license_plate, '35634678');
  assert.equal(draft.extracted_fields.price, '45000');
  assert.deepEqual(draft.license_plate_candidates, ['35634678']);
});

test('failed recovery never pads a five digit plate or discards other audio fields', async () => {
  const {transcribeRecording} = require('../audio-draft');
  let calls = 0;
  const draft = await transcribeRecording({audioBuffer: Buffer.from('audio')}, {
    apiKey: 'test', transcribe: async () => {
      if (++calls === 2) throw new Error('provider unavailable');
      return 'מספר רישוי 35634 המחיר 45000';
    }, request: async () => ({ok: true, json: async () => ({choices: [{message: {content: JSON.stringify({
      license_plate: {value: '35634', evidence: '35634'},
      price: {value: '45000', evidence: '45000'},
    })}}]})}),
  });
  assert.equal(calls, 2);
  assert.equal(draft.extracted_fields.license_plate, undefined);
  assert.deepEqual(draft.license_plate_candidates, []);
  assert.equal(draft.extracted_fields.price, '45000');
});

test('stronger text model recovers Hebrew plate words before retrying audio', async () => {
  const {transcribeRecording} = require('../audio-draft');
  const words = 'שלוש מאות חמישים ושש שלושים וארבע שש מאות שבעים ושמונה';
  const transcript = `מספר רישוי ${words}, המחיר ארבעים אלף`;
  const models = [];
  let recognitionCalls = 0;
  const draft = await transcribeRecording({audioBuffer: Buffer.from('audio')}, {
    apiKey: 'test', transcribe: async () => {recognitionCalls++; return transcript;},
    request: async (_, options) => {
      const payload = JSON.parse(options.body);
      models.push(payload.model);
      assert.equal(payload.messages[1].content, transcript);
      const fields = payload.model === 'gpt-4o' ? {
        license_plate_candidates: [{value: '35634678', evidence: words}],
      } : {price: {value: '40000', evidence: 'ארבעים אלף'}};
      return {ok: true, json: async () => ({choices: [{message: {content: JSON.stringify(fields)}}]})};
    },
  });
  assert.deepEqual(models, ['gpt-4o-mini', 'gpt-4o']);
  assert.equal(recognitionCalls, 1);
  assert.equal(draft.extracted_fields.license_plate, '35634678');
  assert.equal(draft.extracted_fields.price, '40000');
  assert.equal(draft.text, transcript);
});

test('whole Hebrew number words are recognized but price evidence stays excluded', async () => {
  const words = 'שלושים וחמש מיליון שש מאות שלושים וארבע אלף שש מאות שבעים ושמונה';
  const draft = await candidateDraft(`מספר רישוי ${words}`, {
    license_plate_candidates: [{value: '35634678', evidence: words}],
  });
  assert.deepEqual(draft.license_plate_candidates, ['35634678']);
  const priceOnly = await candidateDraft(`המחיר ${words}`, {
    license_plate_candidates: [{value: '35634678', evidence: words}],
  });
  assert.deepEqual(priceOnly.license_plate_candidates, []);
});

test('partial number groups survive model omission for user correction', async () => {
  for (const text of ['17 7237, ...', 'מספר רישוי 17, 7237', 'מספר רכב 17 / 7237']) {
    const draft = await candidateDraft(text, {});
    assert.deepEqual(draft.license_plate_fragments, ['177237'], text);
    assert.deepEqual(draft.license_plate_candidates, []);
    assert.equal(draft.extracted_fields.license_plate, undefined);
  }
  const price = await candidateDraft('המחיר 17 7237', {
    license_plate_candidates: [{value: '177237', evidence: '17 7237'}],
  });
  assert.deepEqual(price.license_plate_fragments, []);
});
