const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const token = 'nib_' + 'a'.repeat(43);
const request = model => ({ protocol: 'nib-agent/1', model, system: 'Reply briefly.', maxTokens: 8, tools: [], messages: [{ role: 'user', parts: [{ type: 'text', text: 'Hello' }] }] });
async function fixture(t, script, authMethod = "claude.ai") {
  const dir = await fs.mkdtemp(path.join(__dirname, '.test-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const executable = path.join(dir, 'fake-cli');
  await fs.writeFile(executable, '#!' + process.execPath + '\n' + `if(process.argv[2]==='auth'){console.log(JSON.stringify({loggedIn:true,authMethod:${JSON.stringify(authMethod)}}));process.exit(0);}` + script, { mode: 0o700 });
  const catalog = path.join(dir, 'models.json');
  await fs.writeFile(catalog, JSON.stringify({ models: [{ slug: 'fake', apply_patch_tool_type: 'freeform' }] }));
  const mod = await import('./agent.mjs');
  const agent = await mod.createAgent({ directory: dir, token, port: 0, host: '127.0.0.1', claude: executable, codex: executable, catalog });
  t.after(() => agent.close());
  const post = (value, auth = token) => fetch(`http://127.0.0.1:${agent.port}/`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${auth}` }, body: JSON.stringify(value) });
  return { agent, post, dir, mod };
}
const fake = `
const a = process.argv.slice(2);
let input = ''; process.stdin.on('data', x => input += x); process.stdin.on('end', () => {
const codex = a[0] === 'exec';
if (input.includes('FAIL_AUTH')) { console.error('not logged in 401'); process.exit(1); }
if (codex) {
const required = ['--ignore-user-config','--ignore-rules','--sandbox','read-only','features.shell_tool=false','web_search="disabled"','features.view_image=false'];
for (const x of required) if (!a.includes(x)) process.exit(23);
const cp = JSON.parse(a.find(x=>x.startsWith('model_catalog_json=')).split('=').slice(1).join('='));
const models = JSON.parse(require('fs').readFileSync(cp)).models;
if (models.some(m=>m.apply_patch_tool_type !== null || m.tool_mode !== 'direct' || m.multi_agent_version !== 'disabled')) process.exit(24);
console.log(JSON.stringify({type:'item.completed',item:{type:'agent_message',text:'Hello from ChatGPT'}}));
console.log(JSON.stringify({type:'turn.completed',usage:{input_tokens:3,output_tokens:4}}));
} else {
if (a[a.indexOf('--tools')+1] !== '' || !a.includes('--strict-mcp-config') || !a.includes('dontAsk')) process.exit(25);
console.log(JSON.stringify({type:'system',subtype:'init',tools:[]}));
console.log(JSON.stringify({type:'stream_event',event:{delta:{type:'text_delta',text:'Hello '}}}));
setTimeout(()=>{console.log(JSON.stringify({type:'stream_event',event:{delta:{type:'text_delta',text:'from Claude'}}}));console.log(JSON.stringify({type:'assistant',message:{content:[{type:'text',text:'Hello from Claude'}]}}));console.log(JSON.stringify({type:'result',usage:{input_tokens:2,output_tokens:3}}));}, 30);
}
});`;
test('Claude streams deltas without repeating the completed message; restrictions are passed', async t => {
  const { post } = await fixture(t, fake);
  const response = await post(request('claude-opus'));
  assert.match(response.headers.get('content-type'), /application\/x-ndjson/);
  const events = (await response.text()).trim().split('\n').map(JSON.parse);
  assert.equal(events.filter(x => x.type === 'textDelta').map(x=>x.text).join(''), 'Hello from Claude');
  assert.deepEqual(events.at(-1), { type: 'stop', reason: 'end_turn' });
});
test('ChatGPT routes to Codex with host tools disabled and a sanitized model catalogue', async t => {
  const { post } = await fixture(t, fake);
  const text = await (await post(request('chatgpt'))).text();
  assert.match(text, /Hello from ChatGPT/); assert.match(text, /"input":3/); assert.match(text, /end_turn/);
});
test('rejects wrong bearer, origins, unknown models and tools without a bridge', async t => {
  const { post, agent } = await fixture(t, fake);
  assert.equal((await post(request('claude'), 'wrong')).status, 401);
  const origin = await fetch(`http://127.0.0.1:${agent.port}`, { method: 'POST', headers: { Origin: 'http://evil.test', Authorization: `Bearer ${token}` } });
  assert.equal(origin.status, 401);
  assert.equal((await post(request('arbitrary'))).status, 400);
  assert.equal((await post({ ...request('claude'), tools: [{ name: 'nib_get', schema: {} }] })).status, 400);
});
test('CLI login errors are actionable and do not leak stderr or secrets', async t => {
  const { post } = await fixture(t, fake);
  const r = request('claude'); r.messages[0].parts[0].text = 'FAIL_AUTH';
  const events = await (await post(r)).text();
  assert.match(events, /not logged in on your Mac/); assert.match(events, /run|Run/); assert.doesNotMatch(events, /Bearer|401/);
});
test('model routing, auth environment, token persistence and pairing', async t => {
  const { mod, dir } = await fixture(t, fake);
  assert.equal(mod.route('claude-sonnet').model, 'sonnet'); assert.equal(mod.route('chatgpt').backend, 'codex');
  const clean = mod.childEnvironment({ PATH: 'x', ANTHROPIC_API_KEY: 'secret', OPENAI_API_KEY: 'secret', HOME: '/home/a' });
  assert.deepEqual(clean, { PATH: 'x', HOME: '/home/a' });
  const saved = await mod.loadToken(dir); assert.equal(await mod.loadToken(dir), saved);
  assert.match(saved, /^nib_[\w-]{43}$/); assert.equal((await fs.stat(path.join(dir, 'token'))).mode & 0o777, 0o600);
  assert.match(mod.pairingString('192.168.1.2', 7332, saved), /^nib:\/\/agent\/pair\?/);
});
test('MCP handoff forwards scoped token and emits one tool call then stops', async t => {
  const bridge = http.createServer(async (req,res) => {
    assert.equal(req.headers.authorization, `Bearer ${token}`);
    let body = ''; for await (const b of req) body += b;
    const rpc = JSON.parse(body);
    res.setHeader('Content-Type','application/json');
    res.end(JSON.stringify({ jsonrpc:'2.0',id:rpc.id,result:{ nibHandoff:true,content:[] } }));
  });
  await new Promise(ok=>bridge.listen(0,'127.0.0.1',ok)); t.after(()=>{bridge.closeAllConnections();bridge.close();});
  const script = `const a=process.argv.slice(2);const c=JSON.parse(a[a.indexOf('--mcp-config')+1]).mcpServers.nib;
process.stdin.resume();fetch(c.url,{method:'POST',headers:{'Content-Type':'application/json',...c.headers},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'nib_get',arguments:{ref:'doc:D'}}})}).then(()=>setTimeout(()=>{},10000));`;
  const { post } = await fixture(t, script);
  const r = { ...request('claude'), tools:[{name:'nib_get',description:'Read',schema:{type:'object'}}], bridge:{url:`http://127.0.0.1:${bridge.address().port}/mcp`, token, mode:'handoff'} };
  const events = (await (await post(r)).text()).trim().split('\n').map(JSON.parse);
  assert.equal(events[0].type,'toolCall');assert.equal(events[0].name,'nib_get');assert.deepEqual(events[0].arguments,{ref:'doc:D'});
  assert.deepEqual(events[1],{type:'stop',reason:'tool_use'});
});
test('refuses a Claude CLI that unexpectedly exposes host tools', async t => {
  const { post } = await fixture(t, `process.stdin.resume();console.log(JSON.stringify({type:'system',subtype:'init',tools:['Bash']}));`);
  assert.match(await (await post(request('claude'))).text(), /"type":"error"/);
});
test('cancelling the HTTP request stops the child and deletes private turn files', async t => {
  const { agent, dir } = await fixture(t, `process.stdin.resume(); console.log(JSON.stringify({type:'stream_event',event:{delta:{type:'text_delta',text:'Started'}}}));setInterval(()=>{},1000);`);
  const control = new AbortController();
  const response = await fetch(`http://127.0.0.1:${agent.port}/`, { method:'POST',signal:control.signal,
    headers:{'Content-Type':'application/json',Authorization:`Bearer ${token}`},body:JSON.stringify(request('claude')) });
  const reader = response.body.getReader(); await reader.read(); control.abort();
  await reader.cancel().catch(()=>{});
  const end = Date.now()+5000;
  while ((await fs.readdir(dir)).some(x=>x.startsWith('turn-')) && Date.now()<end) await new Promise(ok=>setTimeout(ok,50));
  assert.equal((await fs.readdir(dir)).filter(x=>x.startsWith('turn-')).length,0);
});
test('a tool outside the declared scope never reaches the iPad bridge', async t => {
  let called = false;
  const bridge = http.createServer((req,res)=>{called=true;res.end('{}');});
  await new Promise(ok=>bridge.listen(0,'127.0.0.1',ok));t.after(()=>{bridge.closeAllConnections();bridge.close();});
  const script = `const a=process.argv.slice(2),c=JSON.parse(a[a.indexOf('--mcp-config')+1]).mcpServers.nib;process.stdin.resume();
fetch(c.url,{method:'POST',headers:{'Content-Type':'application/json',...c.headers},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'Bash',arguments:{command:'ls'}}})}).then(x=>x.json()).then(x=>{if(!x.error)process.exit(1);console.log(JSON.stringify({type:'assistant',message:{content:[{type:'text',text:'Denied'}]}}));});`;
  const { post } = await fixture(t,script);
  const r = {...request('claude'),tools:[{name:'nib_get',description:'Read',schema:{}}],bridge:{url:`http://127.0.0.1:${bridge.address().port}/mcp`,token,mode:'handoff'}};
  assert.match(await (await post(r)).text(),/Denied/);assert.equal(called,false);
});
test('CLI launch allows only explicitly named Nib tools and approves only the handoff server', async () => {
  const { launchArguments } = await import('./agent.mjs');
  const claude = launchArguments('claude', 'opus', '/private/turn', 'http://127.0.0.1:9999/mcp', token, ['nib_get']);
  assert.equal(claude[claude.indexOf('--allowedTools')+1], 'mcp__nib__nib_get');
  assert.equal(claude[claude.indexOf('--tools')+1], '');
  assert.equal(claude[claude.indexOf('--model')+1], 'opus');
  assert.equal(claude[claude.indexOf('--permission-mode')+1], 'dontAsk');
  assert.equal(JSON.parse(claude[claude.indexOf('--mcp-config')+1]).mcpServers.nib.headers.Authorization, `Bearer ${token}`);
  const codex = launchArguments('codex', undefined, '/private/turn', 'http://127.0.0.1:9999/mcp', token, ['nib_get']);
  assert.ok(codex.includes('mcp_servers.nib.enabled_tools=["nib_get"]'));
  assert.ok(codex.includes('mcp_servers.nib.default_tools_approval_mode="approve"'));
  assert.ok(codex.includes('features.goals=false'));
  assert.ok(codex.includes('features.multi_agent_v2=false'));
  assert.ok(codex.includes('web_search="disabled"'));
  assert.ok(codex.includes('read-only'));
  assert.ok(!claude.concat(codex).some(x => x.includes('dangerously')));
});

test('Claude refuses a stored API-key login instead of billing it', async t => {
  const { post } = await fixture(t, 'console.log("This model process must never start");', 'api_key');
  const output = await (await post(request('claude'))).text();
  assert.match(output, /sign in with your subscription/);
  assert.doesNotMatch(output, /textDelta/);
});
test('server shutdown waits for running CLI cleanup', async t => {
  const { agent, post, dir } = await fixture(t, `process.stdin.resume();console.log(JSON.stringify({type:'stream_event',event:{delta:{type:'text_delta',text:'Started'}}}));setInterval(()=>{},1000);`);
  const response = await post(request('claude'));
  const reader = response.body.getReader();await reader.read();
  await agent.close();
  await reader.cancel().catch(()=>{});
  assert.equal((await fs.readdir(dir)).filter(x=>x.startsWith('turn-')).length,0);
});
