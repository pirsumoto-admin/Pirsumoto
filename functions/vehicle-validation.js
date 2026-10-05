'use strict';
const schema = require('./vehicle-schema.json');
function normalizeHebrewDigits(text = '') {
  const words = {'שמונה עשרה':'18','אפס':'0','אחת':'1','אחד':'1','שתיים':'2','שניים':'2','שתים':'2','שנים':'2','שלוש':'3','שלושה':'3','ארבע':'4','ארבעה':'4','חמש':'5','חמישה':'5','שש':'6','שישה':'6','שבע':'7','שבעה':'7','שמונה':'8','תשע':'9','תשעה':'9','עשר':'10','עשרה':'10'};
  let result = String(text).trim();
  for (const [word, digit] of Object.entries(words)) result = result.replace(new RegExp(`(^|[\\s,.!?])${word}(?=$|[\\s,.!?])`, 'g'), (_, prefix) => prefix + digit);
  return result;
}
function extractPlate(text) {
  const normalized = normalizeHebrewDigits(text);
  const match = normalized.match(/(?:מספר רכב|מספר רישוי|לוחית|רישוי)\s*[:\-]?\s*([\d -]+)/);
  const candidate = (match?.[1] || normalized).trim();
  if (!/^[\d -]+$/.test(candidate)) return null;
  const digits = candidate.replace(/\D/g, '');
  return /^\d{7,8}$/.test(digits) ? digits : null;
}
function normalizeHand(value) {
  return ({'ראשונה':'1','שנייה':'2','שניה':'2','שלישית':'3','רביעית':'4','חמישית':'5'})[value.replace(/^יד\s*/, '')] || value.replace(/^יד\s*/, '');
}
function sanitizeFields(raw, {allowPlate = false} = {}) {
  const output = {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return output;
  for (const [key, rawValue] of Object.entries(raw)) {
    if (!Object.hasOwn(schema.labels, key) || (key === 'license_plate' && !allowPlate)) continue;
    if (!['string','number'].includes(typeof rawValue)) continue;
    let value = String(rawValue).trim();
    if (value.length > (['description', 'highlights'].includes(key) ? 4000 : 200)) continue;
    // Only strip thousands separators in correctly grouped numbers. Preserve invalid values for correction.
    if (['km','price'].includes(key) && /^\d{1,3}(,\d{3})+$/.test(value)) value = value.replace(/,/g, '');
    if (key === 'hand') value = normalizeHand(value);
    if (key === 'clean_title') {
      if (value === 'true' || value === '1') value = 'כן';
      if (value === 'false' || value === '0') value = 'לא';
    }
    if (['current_ownership','previous_ownership'].includes(key)) {
      if (value === 'פרטי') value = 'פרטית';
      if (value === 'או"ם') value = 'או״ם';
    }
    if (key === 'gear_type') {
      if (value === '0') value = 'שידור ידני';
      if (value === '1') value = 'הילוכים אוטומטיים';
    }
    output[key] = value;
  }
  return output;
}
function getMissingFields(state) {
  const disregarded = new Set(['city', 'handicapped', 'no_test', 'govIl', 'includeYad2', 'include_yad2', 'test_until', 'force_show_current_ownership', 'history_records']);
  return schema.required.filter(k => !disregarded.has(k) && !String(state[k] ?? '').trim());
}
function validateValues(state) {
  const errors = [];
  const year = new Date().getFullYear();
  const ranges = {km:[0,1500000],price:[1,100000000],hand:[1,20],year:[1900,year+1],month:[1,12],test_month:[1,12],test_year:[1900,year+3],engine_capacity:[1,20000]};
  const disregarded = new Set(['city', 'handicapped', 'no_test', 'govIl', 'includeYad2', 'include_yad2', 'test_until', 'force_show_current_ownership', 'history_records']);
  for (const [key, value] of Object.entries(state)) {
    if (!value || disregarded.has(key)) continue;
    let invalid = key === 'license_plate' && !/^\d{7,8}$/.test(value);
    if (key === 'phone') invalid ||= !/^(?:0[2-9]\d{7,8}|\+?972[2-9]\d{7,8})$/.test(value);
    if (ranges[key]) invalid ||= !/^\d+$/.test(value) || Number(value) < ranges[key][0] || Number(value) > ranges[key][1];
    // Disregard strict enum validation for color since color text is normalized internally
    if (key !== 'color' && schema.enums[key]) {
      invalid ||= !schema.enums[key].includes(value);
    }
    if (invalid) errors.push(`${schema.labels[key]}: ערך לא תקין`);
  }
  return errors;
}
function extractExplicitFields(text, state) {
  const extracted = {};
  const labels = {...schema.labels, km:"קילומטראז׳", price:"מחיר"};
  const aliases = {"תו נכה":"handicapped", "ללא טסט":"no_test", "חודש עלייה לכביש":"month", "גיר":"gear_type", "קמ":"km", "ק״מ":"km", "קילומטראז":"km", "מחיר מבוקש":"price", "שנה":"year", "בעלות":"current_ownership", "חודש":"month", "מצב":"vehicle_condition"};
  const reverse = Object.fromEntries(Object.entries(labels).map(([k,v])=>[v,k]));
  const lines = String(text).split(/[;\n]+/).map(s=>s.trim()).filter(Boolean);
  for (const line of lines) {
    const match = line.match(/^([^:=]+)[:=]\s*(.*)$/);
    if (!match) continue;
    const label = match[1].trim();
    const key = Object.hasOwn(schema.labels,label) ? label : reverse[label] || aliases[label];
    if (key && key !== 'license_plate') extracted[key]=match[2];
  }
  // A single answer is unambiguous only if exactly one field was requested.
  const missing=getMissingFields(state);
  if (!Object.keys(extracted).length && missing.length===1 && missing[0]!=='license_plate' && lines.length===1 && !/[?:=]/.test(text)) extracted[missing[0]]=text.trim();
  return sanitizeFields(extracted);
}
function guidance(state, imageCount) {
  const missing = getMissingFields(state), errors = validateValues(state);
  if (!state.license_plate) return 'כדי להתחיל, שלח מספר רישוי בן 7 או 8 ספרות.';
  if (missing.length || errors.length) return [...errors, ...(missing.length ? ['להשלמת פרטי רכב חסרים:', ...missing.map(k => `• ${schema.labels[k]}`)] : [])].join('\n');
  return imageCount > 0 ? '✅ הפרטים מוכנים. לחץ על ״פרסם עכשיו״ להוספה לתור.' : '✅ הפרטים מלאים. צרף לפחות תמונה אחת כדי לפרסם.';
}
module.exports = {extractExplicitFields, schema, normalizeHebrewDigits, normalizeHand, extractPlate, sanitizeFields, getMissingFields, validateValues, guidance};
