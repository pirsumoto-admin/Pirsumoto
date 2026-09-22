const test=require('node:test');
const assert=require('node:assert/strict');
const {createPublicationApi}=require('../publication-api');
const v=require('../vehicle-validation');
const vehicle={license_plate:'1234567',maker:'Toyota',model:'Corolla',year:'2020',km:'100000',price:'70000',hand:'2',color:'לבן',fuel_type:'בנזין',gear_type:'אוטומטי',current_ownership:'פרטית',previous_ownership:'פרטית',month:'5',vehicle_condition:'טוב',city:'חיפה',handicapped:'לא',no_test:'לא'};
function fixture() {
  const records=new Map([['remote_control_devices/device',{ownerUid:'owner'}]]);
  const reads=[];
  const snapshot=path=>({id:path.split('/').at(-1),ref:ref(path),exists:records.has(path),data:()=>structuredClone(records.get(path))});
  const query=(path,filters=[],order=null,max=Infinity,after=null)=>({
    doc:id=>ref(`${path}/${id}`),
    where:(key,op,value)=>query(path,[...filters,[key,value]],order,max,after),
    orderBy:key=>query(path,filters,key,max,after),
    limit:n=>query(path,filters,order,n,after),
    startAfter:doc=>query(path,filters,order,max,doc.ref.path),
    get:async()=>{
      reads.push(path+'/*');
      let matches=[...records].filter(([key,data])=>key.startsWith(path+'/') && key.split('/').length===path.split('/').length+1 && filters.every(([k,v])=>data[k]===v));
      if(order)matches.sort((a,b)=>a[1][order]-b[1][order]);
      if(after) matches=matches.slice(matches.findIndex(([key])=>key===after)+1);
      return {docs:matches.slice(0,max).map(([key])=>snapshot(key))};
    }
  });
  const ref=path=>({path,get:async()=>{reads.push(path);return snapshot(path);},collection:name=>query(`${path}/${name}`)});
  let serial=Promise.resolve();
  const db={collection:name=>query(name),runTransaction:fn=>{
    const result=serial.then(async()=>{
      const writes=[];const tx={get:async r=>r.get(),set:(r,data,options)=>writes.push(()=>records.set(r.path,options?.merge ? {...records.get(r.path),...data} : data)),update:(r,data)=>writes.push(()=>records.set(r.path,{...records.get(r.path),...data}))};
      const value=await fn(tx);for(const write of writes)write();return value;
    });serial=result.catch(()=>{});return result;
  }};
  const admin={auth:()=>({verifyIdToken:async token=>{if(token!=='valid')throw Error();return {uid:'owner'};}}),
    firestore:{Timestamp:{fromMillis:value=>value},FieldValue:{serverTimestamp:()=>123}},storage:()=>({bucket:()=>({file:()=>({getMetadata:async()=>[{size:4,contentType:'image/jpeg',generation:'1'}]})})})};
  return {api:createPublicationApi(admin,db),records,reads};
}
const enqueue={action:'enqueue_publication',deviceId:'device',requestId:'car',attemptId:'attempt',vehicleData:vehicle,
  attachments:[{path:'publication_media/owner/device/car/attempt/0',size:4,sha256:'a'.repeat(64)}]};

test('requires valid authentication and ownership before any provider action',async()=>{
  const {api,records}=fixture();
  await assert.rejects(api.authorize({headers:{}},{deviceId:'device'}),{status:401});
  await assert.rejects(api.authorize({headers:{authorization:'Bearer invalid'}},{deviceId:'device'}),{status:401});
  records.set('remote_control_devices/device',{ownerUid:'someone_else'});
  await assert.rejects(api.authorize({headers:{authorization:'Bearer valid'}},{deviceId:'device'}),{status:403});
});
test('rate limit is persistent and applied across calls',async()=>{
  const {api}=fixture();const req={headers:{authorization:'Bearer valid'}};
  for(let i=0;i<60;i++)await api.authorize(req,{deviceId:'device'});
  await assert.rejects(api.authorize(req,{deviceId:'device'}),{status:429});
});
test('simultaneous duplicate submissions create one immutable publication attempt',async()=>{
  const {api,records}=fixture();
  const [one,two]=await Promise.all([api.handle(structuredClone(enqueue),'owner'),api.handle(structuredClone(enqueue),'owner')]);
  assert.equal(one.request.attemptId,two.request.attemptId);
  assert.equal(records.get('remote_chats/device/requests/car').revision,1);
});
test('canceling a queued request does not alter the active device reservation',async()=>{
  const {api,records}=fixture();records.set('remote_chats/device',{activeRequestId:'other'});
  await api.handle(structuredClone(enqueue),'owner');
  const response=await api.handle({...enqueue,action:'control_publication',command:'cancel'},'owner');
  assert.equal(response.request.state,'canceled');assert.equal(records.get('remote_chats/device').activeRequestId,'other');
});
test('active cancellation waits for worker acknowledgment and cannot be resumed',async()=>{
  const {api,records}=fixture();await api.handle(structuredClone(enqueue),'owner');
  records.get('remote_chats/device/requests/car').state='publishing';
  const response=await api.handle({...enqueue,action:'control_publication',command:'cancel'},'owner');
  assert.equal(response.request.state,'canceling');
  await assert.rejects(api.handle({...enqueue,action:'control_publication',command:'resume'},'owner'),{status:409});
  await assert.rejects(api.handle({...enqueue,attemptId:'old',action:'control_publication',command:'cancel'},'owner'),{status:409});
});
test('missing vehicle fields and foreign/missing attachments fail closed',async()=>{
  const {api}=fixture();
  await assert.rejects(api.handle({...enqueue,vehicleData:{license_plate:'1234567'}},'owner'),{status:400});
  await assert.rejects(api.handle({...enqueue,attachments:[]},'owner'),{status:400});
  await assert.rejects(api.handle({...enqueue,attachments:[{...enqueue.attachments[0],path:'publication_media/other/0'}]},'owner'),{status:400});
  await assert.rejects(api.handle({...enqueue,attachments:[{...enqueue.attachments[0],size:5}]},'owner'),{status:400});
});
test('validation rejects malformed numbers and model-invented internal fields',()=>{
  assert.deepEqual(v.sanitizeFields({license_plate:'9999999',image_paths:'secret',apiKey:'secret',km:'-50'}),{km:'-50'});
  assert.equal(v.validateValues({km:'-50',price:'1000oops',hand:'banana',fuel_type:'banana',license_plate:'abc'}).length,5);
  assert.deepEqual(v.getMissingFields(vehicle),[]);
  assert.equal(v.normalizeHebrewDigits('שמונה עשרה'),'18');
  assert.equal(v.extractPlate('מספר רכב שבע שמונה שמונה שתיים ארבע שלוש שלוש'),'7882433');
  assert.equal(v.extractPlate('מחיר 1234567'),null);
});
test('explicit corrections preserve zero mileage and thousands separators',()=>{
  assert.deepEqual(v.extractExplicitFields('km: 0; מחיר: 120,000',vehicle),{km:'0',price:'120000'});
});

test('priority changes the next candidate without disturbing the active reservation', async()=>{
  const {api,records}=fixture();
  records.set('remote_chats/device',{activeRequestId:'active',workerRunId:'worker'});
  await api.handle(structuredClone(enqueue),'owner');
  await api.handle({...enqueue,action:'prioritize_publication'},'owner');
  assert.deepEqual(records.get('remote_chats/device'),{activeRequestId:'active',workerRunId:'worker'});
  assert.deepEqual(records.get('remote_publication_queues/device'),{ownerUid:'owner',nextRequestId:'car'});
});
test('retry returns the immutable original even after attachments are unavailable', async()=>{
  const {api}=fixture();
  await api.handle(structuredClone(enqueue),'owner');
  const result=await api.handle({...enqueue,attemptId:'new_attempt',attachments:[],vehicleData:{}},'owner');
  assert.equal(result.request.attemptId,'attempt');
});
test('null attachment is a validation error, not an internal failure', async()=>{
  const {api}=fixture();
  await assert.rejects(api.handle({...enqueue,attachments:[null]},'owner'),{status:400});
});

test('draft traffic cannot exhaust worker OCR or publication-control budgets', async()=>{
  const {api,records}=fixture(); const req={headers:{authorization:'Bearer valid'}};
  for(let i=0;i<60;i++) await api.authorize(req,{deviceId:'device',action:'process_turn'});
  await assert.rejects(api.authorize(req,{deviceId:'device',action:'process_turn'}),{status:429});
  await api.authorize(req,{deviceId:'device',action:'worker_ocr'});
  await api.authorize(req,{deviceId:'device',action:'control_publication'});
  assert.equal(records.get('remote_validation_limits/owner_device_worker').count,1);
  assert.equal(records.get('remote_validation_limits/owner_device_control').count,1);
});
test('a completed attempt cannot be replayed by a late enqueue retry', async()=>{
  const {api,records}=fixture(); await api.handle(structuredClone(enqueue),'owner');
  records.get('remote_chats/device/requests/car').state='completed';
  const result=await api.handle(structuredClone(enqueue),'owner');
  assert.equal(result.request.state,'completed');
});

const claim={action:'claim_publication',deviceId:'device',workerRunId:'run_one'};
test('dispatch atomically reserves and returns only one car across competing workers', async()=>{
  const {api,records}=fixture();
  await api.handle(structuredClone(enqueue),'owner');
  records.set('remote_chats/device/requests/later',{...records.get('remote_chats/device/requests/car'),requestId:'later',attemptId:'later_attempt',enqueuedAt:999});
  const results=await Promise.all([api.handle(claim,'owner'),api.handle({...claim,workerRunId:'run_two'},'owner')]);
  assert.equal(results.filter(r=>r.request!==null).length,1);
  assert.equal(results[0].request.requestId,'car');
  assert.equal(results[0].request.state,'preparing');
  assert.equal(records.get('remote_chats/device').activeRequestId,'car');
  assert.equal(records.get('remote_chats/device/requests/later').state,'queued');
});
test('busy dispatch reads no queue metadata or other cars', async()=>{
  const {api,records,reads}=fixture();
  records.set('remote_chats/device',{activeRequestId:'active',workerRunId:'run_one'});
  const result=await api.handle(claim,'owner');
  assert.equal(result.request,null);
  assert.deepEqual(reads,['remote_control_devices/device','remote_chats/device']);
});
test('dispatch honors private queue priority and checks ownership inside transaction', async()=>{
  const {api,records}=fixture();
  await api.handle(structuredClone(enqueue),'owner');
  records.set('remote_chats/device/requests/later',{...records.get('remote_chats/device/requests/car'),requestId:'later',attemptId:'later_attempt',enqueuedAt:999});
  records.set('remote_publication_queues/device',{ownerUid:'owner',nextRequestId:'later'});
  assert.equal((await api.handle(claim,'owner')).request.requestId,'later');
  assert.equal(records.get('remote_publication_queues/device').nextRequestId,null);
  records.set('remote_control_devices/device',{ownerUid:'new_owner'});
  await assert.rejects(api.handle(claim,'owner'),{status:403});
});

test('empty queue stays empty after cancel and archive, then dispatches the first new car', async()=>{
  const {api,records}=fixture();
  assert.equal((await api.handle(claim,'owner')).request,null);
  await api.handle(structuredClone(enqueue),'owner');
  await api.handle({...enqueue,action:'prioritize_publication'},'owner');
  await api.handle({...enqueue,action:'control_publication',command:'cancel'},'owner');
  await api.handle({...enqueue,action:'archive_publication'},'owner');
  assert.equal(records.get('remote_publication_queues/device').nextRequestId,null);
  assert.equal((await api.handle(claim,'owner')).request,null);
  records.set('remote_chats/device/requests/new',{...records.get('remote_chats/device/requests/car'),
    requestId:'new',attemptId:'new_attempt',archived:false,state:'queued',enqueuedAt:999});
  assert.equal((await api.handle(claim,'owner')).request.requestId,'new');
});
test('legacy archived queued records and stale priority cannot block or be dispatched', async()=>{
  const {api,records}=fixture();
  await api.handle(structuredClone(enqueue),'owner');
  for(let i=0;i<30;i++) records.set(`remote_chats/device/requests/deleted_${i}`,{
    ...records.get('remote_chats/device/requests/car'),requestId:`deleted_${i}`,archived:true,enqueuedAt:i});
  records.set('remote_publication_queues/device',{ownerUid:'owner',nextRequestId:'deleted_0'});
  assert.equal((await api.handle(claim,'owner')).request.requestId,'car');
  assert.equal(records.get('remote_chats/device/requests/deleted_0').state,'queued');
});
test('archive of active job is rejected and cannot free a live reservation', async()=>{
  const {api,records}=fixture();
  await api.handle(structuredClone(enqueue),'owner');
  await api.handle(claim,'owner');
  await assert.rejects(api.handle({...enqueue,action:'archive_publication'},'owner'),{status:409});
  assert.equal(records.get('remote_chats/device').activeRequestId,'car');
});
