// Real subscription smoke. Starts/stops only its own agent; no credentials printed.
import { createAgent } from './agent.mjs';
import { spawn } from 'node:child_process';
import http from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
const directory = await mkdtemp(join(fileURLToPath(new URL('.', import.meta.url)), '.smoke-'));
const agent = await createAgent({ directory, host: '127.0.0.1', port: 0 });
let bridge;
const tool = { name: 'nib_context', description: 'Read the current Nib context.', schema: { type: 'object', properties: {} } };
if (process.env.NIB_SMOKE_TOOLS === '1') {
  bridge = http.createServer(async (req, res) => {
    if (req.headers.authorization !== `Bearer ${agent.token}`) { res.writeHead(401); return res.end(); }
    let input = ''; for await (const chunk of req) input += chunk;
    const rpc = JSON.parse(input); let result = {};
    if (rpc.method === 'notifications/initialized') { res.writeHead(202); return res.end(); }
    if (rpc.method === 'initialize') result = { protocolVersion:'2025-03-26', capabilities:{tools:{}}, serverInfo:{name:'nib-smoke',version:'1'} };
    if (rpc.method === 'tools/list') result = { tools:[{name:tool.name,description:tool.description,inputSchema:tool.schema}] };
    if (rpc.method === 'tools/call') {
      if (rpc.params.name !== tool.name) { res.writeHead(403); return res.end(); }
      result = { nibHandoff:true,content:[] };
    }
    res.setHeader('Content-Type','application/json');res.end(JSON.stringify({jsonrpc:'2.0',id:rpc.id,result}));
  });
  await new Promise(ok => bridge.listen(0, '127.0.0.1', ok));
}
try {
  for (const model of (process.env.NIB_SMOKE_MODELS || 'claude-sonnet,chatgpt').split(',')) {
    const payload = JSON.stringify({ protocol: 'nib-agent/1', model, system: 'Answer in one short sentence.', maxTokens: 32, tools: bridge ? [tool] : [], ...(bridge ? {bridge:{url:`http://127.0.0.1:${bridge.address().port}/mcp`,token:agent.token,mode:'handoff'}} : {}), messages: [{ role: 'user', parts: [{ type: 'text', text: process.env.NIB_SMOKE_PROMPT || 'Say hello from Nib.' }] }] });
    const curl = spawn('curl', ['--silent', '--show-error', '--no-buffer', '--max-time', '180', '--config', '-'], { stdio: ['pipe', 'pipe', 'inherit'] });
    curl.stdin.end(`url = "http://127.0.0.1:${agent.port}/"\nrequest = "POST"\nheader = "Authorization: Bearer ${agent.token}"\nheader = "Content-Type: application/json"\ndata = ${JSON.stringify(payload)}\n`);
    let output = '';
    for await (const chunk of curl.stdout) { output += chunk; process.stdout.write(`${model}: ${chunk}`); }
    const code = await new Promise(ok => { if (curl.exitCode !== null) ok(curl.exitCode); else curl.once('close', ok); });
    if (code !== 0 || !output.includes(bridge ? '"type":"toolCall"' : '"type":"textDelta"') || output.includes('"type":"error"')) process.exitCode = 1;
  }
} finally { bridge?.closeAllConnections(); bridge?.close(); await agent.close(); await rm(directory, { recursive: true, force: true }); }
