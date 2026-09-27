#!/usr/bin/env python3
"""End-to-end JSON-RPC/stdio tests against an isolated FlowHarness service."""
import json, os, pathlib, queue, subprocess, tempfile, threading, time

PROJECT = pathlib.Path(__file__).resolve().parent.parent
BIN = PROJECT / '.build/debug'
FFMPEG = next(p for p in ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'] if pathlib.Path(p).exists())

class Client:
    def __init__(self, env):
        self.p = subprocess.Popen([str(BIN / 'lovemeliya-flow-mcp'), '--stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True, bufsize=1)
        self.lines = queue.Queue(); self.index = 0
        def reader():
            for line in self.p.stdout:
                try: self.lines.put(json.loads(line))
                except Exception as error: self.lines.put(error)
        threading.Thread(target=reader, daemon=True).start()
        initialized = self.rpc('initialize', {'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'Flow E2E','version':'1.0'}})
        assert initialized['result']['serverInfo']['name'] == 'lovemeliya-flow', initialized
        self.notify('notifications/initialized', {})
    def notify(self, method, params):
        self.p.stdin.write(json.dumps({'jsonrpc':'2.0','method':method,'params':params})+'\n'); self.p.stdin.flush()
    def rpc(self, method, params):
        self.index += 1; request_id = self.index
        self.p.stdin.write(json.dumps({'jsonrpc':'2.0','id':request_id,'method':method,'params':params})+'\n'); self.p.stdin.flush()
        deadline = time.monotonic()+45
        while time.monotonic()<deadline:
            message = self.lines.get(timeout=max(.01,deadline-time.monotonic()))
            assert not isinstance(message,Exception), 'Non-JSON stdout: '+str(message)
            if message.get('id')==request_id: return message
        raise TimeoutError(method)
    def tool(self, name, args=None, error=None):
        response=self.rpc('tools/call',{'name':name,'arguments':args or {}})
        assert 'result' in response, response
        result=response['result']; data=result['structuredContent']
        if error: assert result['isError'] and data['error']['code']==error, response
        else: assert not result['isError'],response
        return data
    def close(self):
        if self.p.poll() is None:
            self.p.stdin.close()
            try: self.p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.p.kill(); raise AssertionError('MCP server did not exit on stdin EOF')
            assert self.p.returncode == 0, self.p.stderr.read()

with tempfile.TemporaryDirectory(prefix='flow-e2e-') as temp:
    root=pathlib.Path(temp).resolve(); support=root/'support'; support.mkdir()
    policy={'enabled':True,'requireApproval':False,'readDirectories':[str(root)],'writeDirectories':[str(root)]}
    (support/'ai-policy.json').write_text(json.dumps(policy))
    env={**os.environ,'FLOW_SUPPORT_DIRECTORY':str(support),'FLOW_NO_AUTO_LAUNCH':'1'}
    video=root/"测试 ' $(安全).mp4"
    subprocess.run([FFMPEG,'-v','error','-f','lavfi','-i','testsrc2=size=1280x720:rate=30','-f','lavfi','-i','sine=sample_rate=16000','-t','12','-c:v','libx264','-preset','ultrafast','-c:a','aac',str(video)],check=True)
    host=subprocess.Popen([str(BIN/'FlowHarness')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    client=None
    try:
        # Tool initialization retries are intentionally absent in the server harness test.
        for _ in range(100):
            if (support/'ai-policy.json').exists():
                time.sleep(.05)
                import hashlib
                sock=pathlib.Path('/tmp')/f'lovemeliya-flow-{os.getuid()}-{hashlib.sha256(str(support).encode()).hexdigest()[:16]}'/'bridge.sock'
                if sock.exists():break
        client=Client(env)
        listed=client.rpc('tools/list',{})['result']['tools']
        assert len(listed)==7 and all('inputSchema' in tool for tool in listed)
        assert client.tool('flow_capabilities')['enabled']
        client.tool('flow_inspect',{'path':'/etc/hosts'},error='ACCESS_DENIED')
        info=client.tool('flow_inspect',{'path':str(video)})['media']
        assert info['sampleRate']==16000 and info['channels']==1,info
        plan=client.tool('flow_plan',{'inputs':[str(video)],'preset':'wav','audio':{'sample_rate':'source','channels':'source'},'output_directory':str(root)})
        assert not (root/(video.stem+'.wav')).exists()
        submission=client.tool('flow_submit',{'plan_id':plan['plan_id'],'request_id':'wav-1'})
        again=client.tool('flow_submit',{'plan_id':plan['plan_id'],'request_id':'wav-1'})
        assert again['duplicate'] and again['job_ids']==submission['job_ids']
        client.close(); client=None
        # Conversion persists in the host after the client disconnects.
        time.sleep(.3)
        client=Client(env)
        job_id=submission['job_ids'][0]
        deadline=time.monotonic()+20
        while True:
            job=client.tool('flow_get_job',{'job_id':job_id})
            if job['status'] in ['completed','failed','cancelled']:break
            assert time.monotonic()<deadline;time.sleep(.1)
        assert job['status']=='completed',job
        assert pathlib.Path(job['output_path']).name==video.stem+'.wav',job
        assert job['output_media']['sampleRate']==16000 and job['output_media']['channels']==1,job
        assert len(client.tool('flow_list_jobs',{'batch_id':submission['batch_id']})['jobs'])==1
        # Cancel an actually running long conversion while retaining the completed WAV.
        second=client.tool('flow_plan',{'inputs':[str(video)],'preset':'webm','output_directory':str(root)})
        sub=client.tool('flow_submit',{'plan_id':second['plan_id'],'request_id':'cancel-me'})
        jid=sub['job_ids'][0]
        client.tool('flow_cancel',{'job_id':jid})
        deadline=time.monotonic()+10
        while True:
            cancelled=client.tool('flow_get_job',{'job_id':jid})
            if cancelled['status']=='cancelled':break
            assert time.monotonic()<deadline,cancelled;time.sleep(.1)
        assert pathlib.Path(job['output_path']).exists()
        assert not list(root.glob('.mediaflow-*'))
        # Unknown tool/argument errors remain structured, without crashing the session.
        client.tool('unknown',{},error='UNKNOWN_TOOL')
        client.tool('flow_cancel',{},error='INVALID_ARGUMENTS')
        client.tool('flow_list_jobs',{'limit':-1},error='INVALID_ARGUMENTS')
        client.close();client=None
        print('PASS: 7 tools, initialize/list/call, directory checks, actual WAV conversion, idempotency, disconnect/reconnect, running-job cancellation, structured errors, clean stdout/EOF')
    finally:
        if client:
            try:client.close()
            except Exception:client.p.kill()
        host.terminate()
        try:host.wait(timeout=5)
        except subprocess.TimeoutExpired:host.kill()
        if host.returncode not in (0,-15): print(host.stderr.read())
