const test = require('node:test');
const assert = require('node:assert/strict');
const {mediaExpired} = require('../publication-retention');
const now = Date.UTC(2026,8,21), day=86400000;
const name='publication_media/owner/device/car/attempt/0';
const metadata={timeCreated:new Date(now-60*day).toISOString()};
const request={ownerUid:'owner',attemptId:'attempt',updatedAt:{toMillis:()=>now-31*day}};
test('retention never deletes active/paused/stuck/canceling jobs regardless of age',()=>{
  for(const state of ['queued','preparing','publishing','paused','stuck','canceling']) assert.equal(mediaExpired(name,metadata,{...request,state},now),false);
});
test('only old terminal media or old abandoned attempts expire',()=>{
  for(const state of ['completed','failed','canceled']) assert.equal(mediaExpired(name,metadata,{...request,state},now),true);
  assert.equal(mediaExpired(name,metadata,{...request,state:'completed',updatedAt:{toMillis:()=>now-day}},now),false);
  assert.equal(mediaExpired(name,metadata,null,now),true);
  assert.equal(mediaExpired(name,{timeCreated:new Date(now-day).toISOString()},null,now),false);
  assert.equal(mediaExpired(name,{},null,now),false);
  assert.equal(mediaExpired('other/file',metadata,null,now),false);
});
