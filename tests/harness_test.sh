#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
exec python3 - "$root" <<'PYTHON'
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
count = 0
CONTROL_KEYS = (
    "REMOTE", "MISSING_IMAGE", "WRONG_OWNER", "CONFIG_HASH", "APP_STATE",
    "HEALTH", "FAIL_DAEMON", "VERIFY_EXIT", "FAIL_UP", "BAD_MODEL",
)

def run(args, cwd, env=None, code=0, text=None):
    if args and str(args[0]) == str(source / 'scripts/stack.sh'):
        scenario.write_text(json.dumps({key: value for key, value in (env or {}).items() if key in CONTROL_KEYS}))
    p = subprocess.run([str(x) for x in args], cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert p.returncode == code and (not text or text in p.stdout), str(args) + ' expected=' + str(code) + ' actual=' + str(p.returncode) + '\n' + p.stdout
    return p.stdout

def ok(name):
    global count
    count += 1
    print('PASS ' + name, flush=True)

with tempfile.TemporaryDirectory(prefix='ej-contract-') as temporary:
    base = Path(temporary)
    repo = base / 'repo with spaces'
    repo.mkdir()
    run(['git', 'init', '-q', str(repo)], base)
    (repo / 'mix.exs').write_text('# audited fake project\n')
    (repo / 'source.ex').write_text('original\n')
    (repo / 'scripts').mkdir()
    shutil.copy2(source / 'templates/elixir/scripts/verify.sh', repo / 'scripts/verify.sh')
    (repo / '.githooks').mkdir()
    shutil.copy2(source / 'templates/elixir/.githooks/pre-commit', repo / '.githooks/pre-commit')
    run(['git', 'add', '.'], repo)
    run(['git', '-c', 'user.name=Harness', '-c', 'user.email=harness@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], repo)
    tools = base / 'bin'; tools.mkdir()
    mix = tools / 'mix'
    mix.write_text('''#!/bin/sh
printf '%s %s\\n' "$MIX_ENV" "$*" >> "$MIX_LOG"
if [ "$MUTATE_SOURCE" = 1 ] && [ "$1" = compile ]; then echo changed >> source.ex; fi
if [ "$FAIL_TASK" = "$1" ]; then exit 17; fi
'''+ '\nexit 0\n')
    mix.chmod(0o755)
    log = base / 'mix.log'
    env = dict(os.environ, PATH=str(tools)+os.pathsep+os.environ['PATH'], MIX_LOG=str(log))
    gate = repo / 'scripts/verify.sh'
    run([gate, 'fast'], base, env)
    assert log.read_text().splitlines() == ['dev format --check-formatted', 'dev compile --warnings-as-errors']
    ok('fast commands, script-relative root and paths with spaces')
    log.write_text('')
    run([gate, 'full'], base, env, text='working-tree inputs only')
    assert log.read_text().splitlines() == ['dev format --check-formatted', 'dev compile --warnings-as-errors', 'test test']
    ok('full includes fast then test; no commit-verification claim')
    for task, calls in [('format',1), ('compile',2), ('test',3)]:
        log.write_text('')
        run([gate, 'full'], base, dict(env, FAIL_TASK=task), 17, 'RESULT exit=17')
        assert len(log.read_text().splitlines()) == calls
        ok('negative '+task+': exit preserved; subsequent commands stopped')
    for args in [[], ['wrong'], ['fast','extra']]: run([gate]+args, base, env, 2)
    ok('negative missing/invalid/extra arguments')
    (repo/'mix.exs').rename(repo/'saved')
    run([gate,'fast'], base, env, 2, 'no mix.exs')
    (repo/'saved').rename(repo/'mix.exs')
    ok('negative missing Mix root')
    missing = base/'missing'; missing.mkdir()
    for tool in ['git','dirname']: (missing/tool).symlink_to(shutil.which(tool))
    run(['/bin/sh',gate,'fast'], base, dict(env,PATH=str(missing)),3,'missing mix')
    ok('negative missing executable')
    (repo/'source.ex').write_text('staged\n'); run(['git','add','source.ex'],repo)
    (repo/'source.ex').write_text('staged\nunstaged\n'); (repo/'untracked.ex').write_text('untracked\n')
    run([gate,'fast'],repo,env,text='partial staging is not verified')
    ok('dirty/untracked and partial-staging disclosure')
    run([gate,'fast'],repo,dict(env,MUTATE_SOURCE='1'),1,'tracked inputs or HEAD changed')
    assert 'changed' in (repo/'source.ex').read_text()
    ok('negative source mutation; no automatic restoration')
    log.write_text(''); run([repo/'.githooks/pre-commit'],repo/'scripts',env,text='not the staged snapshot')
    assert len(log.read_text().splitlines())==2
    ok('hook invokes canonical fast gate from nested directory')

    docker = tools/'docker'
    scenario = base/'docker-scenario.json'
    dockerlog = base/'docker.log'
    metadata = base/'meta.json'
    docker.write_text('#!/usr/bin/env python3\n' +
        'SCENARIO = ' + repr(str(scenario)) + '\n' +
        'LOG = ' + repr(str(dockerlog)) + '\n' +
        'METADATA = ' + repr(str(metadata)) + '\n' + r'''import json,os,sys
from pathlib import Path
assert not any(key in os.environ for key in ('EJ_TEST_HOST_SECRET', 'GITHUB_TOKEN', 'AWS_SECRET_ACCESS_KEY'))
assert not any(key.startswith('COMPOSE_') for key in os.environ)
assert os.environ.get('DOCKER_CONTEXT') == 'ej-test-local'
control=json.loads(Path(SCENARIO).read_text())
a=sys.argv[1:]
with open(LOG,'a') as f: f.write(json.dumps(a)+'\n')
if a[:2]==['context','inspect']: print('tcp://remote.invalid' if control.get('REMOTE') else 'unix:///fake.sock')
elif a[:2]==['image','inspect']:
 if control.get('MISSING_IMAGE'): sys.exit(8)
 print('[]')
elif a[0]=='inspect':
 m=json.loads(Path(METADATA).read_text())
 print(json.dumps([{'Config':{'Labels':{'com.docker.compose.project': 'foreign' if control.get('WRONG_OWNER') else m['project'],'com.docker.compose.service':'app','com.docker.compose.project.working_dir':m['repo'],'com.docker.compose.config-hash':control.get('CONFIG_HASH','hash1')}},'State':{'Status':control.get('APP_STATE','running'),'Health':{'Status':control.get('HEALTH','healthy')}}}]))
elif a[0]=='compose':
 project=a[a.index('--project-name')+1]; repo=a[a.index('--project-directory')+1]
 Path(METADATA).write_text(json.dumps({'project':project,'repo':repo}))
 c=json.loads((Path(repo)/'.elixir-journey/stack.json').read_text())
 if 'config' in a:
  if '--hash' in a: print('app hash1')
  else:
   app={'image':'local-app:fixture','healthcheck':{'test':['CMD','true']},'ports':[{'published':str(c['host_port']),'host_ip':'127.0.0.1','protocol':'tcp'}]}
   bad=control.get('BAD_MODEL')
   privileges={'pid':'host','ipc':'host','uts':'host','cgroup':'host',
               'devices':['/dev/example:/dev/example'],'device_cgroup_rules':['a *:* rwm'],
               'gpus':'all','cap_add':['SYS_ADMIN'],'userns_mode':'host',
               'security_opt':['seccomp=unconfined'],'runtime':'custom','use_api_socket':True}
   if bad in privileges: app[bad]=privileges[bad]
   if bad in ('deploy_devices','empty_deploy_devices'):
    devices = [] if bad=='empty_deploy_devices' else [{'driver':'nvidia','count':'all','capabilities':['gpu']}]
    app['deploy']={'resources':{'reservations':{'devices':devices}}}
   if bad=='empty_cap_add': app['cap_add']=[]
   if bad=='restrictive_security_opt': app['security_opt']=['no-new-privileges:true']
   if bad=='dependency': app['depends_on']={'db':{}}
   if bad=='name': app['container_name']='shared'
   if bad=='volumes_from': app['volumes_from']=['foreign-container']
   if bad=='bind': app['volumes']=[{'type':'bind','source':'/outside-worktree','target':'/private'}]
   if bad=='health': app['healthcheck']={'test':['NONE']}
   if bad=='port': app['ports'][0]['host_ip']='0.0.0.0'
   model={'services':{'app':app},'networks':{'default':{'name':project+'_default'}}}
   if bad=='volume': model['volumes']={'data':{'external':True,'name':'existing-data'}}
   if bad=='volume_bind': model['volumes']={'data':{'name':project+'_data','driver_opts':{'type':'none','o':'bind','device':'/outside-worktree'}}}
   if bad=='volume_driver': model['volumes']={'data':{'name':project+'_data','driver':'other'}}
   if bad=='network_driver': model['networks']={'default':{'name':project+'_default','driver':'macvlan'}}
   print(json.dumps(model))
 elif 'ps' in a:
  if control.get('FAIL_DAEMON'): sys.exit(8)
  if control.get('APP_STATE','absent')!='absent': print('fixture-container')
 elif 'exec' in a: sys.exit(int(control.get('VERIFY_EXIT','0')))
 elif 'up' in a and control.get('FAIL_UP'): sys.exit(9)
''')
    docker.chmod(0o755)
    env=dict(env, EJ_TEST_HOST_SECRET='fake-sensitive-token',
             GITHUB_TOKEN='fake-github-token', AWS_SECRET_ACCESS_KEY='fake-cloud-secret',
             COMPOSE_PROFILES='must-not-inherit', DOCKER_CONTEXT='ej-test-local')
    env.pop('DOCKER_HOST',None)
    stack=source/'scripts/stack.sh'
    run([stack,'--help'],repo,env)
    run([stack,'doctor'],repo,env,2,'missing .elixir-journey')
    ok('stack help and missing adapter refusal')
    (repo/'.elixir-journey').mkdir()
    (repo/'compose.agent.yaml').write_text('# fake normalized model\n')
    adapter={'version':1,'compose_files':['compose.agent.yaml'],'app_service':'app','app_workdir':'/workspace','host_port':54000}
    def configure(): (repo/'.elixir-journey/stack.json').write_text(json.dumps(adapter))
    configure()
    run([stack,'doctor'],repo,env,text='doctor passed')
    ok('doctor validates config, local endpoint and image')
    ok('host tokens and COMPOSE overrides absent from Docker children; required context retained')
    for bad in ['dependency','name','bind','health','port','volume','volumes_from','volume_bind','volume_driver','network_driver','pid','ipc','uts','cgroup','devices','device_cgroup_rules','gpus','cap_add','userns_mode','security_opt','runtime','use_api_socket','empty_cap_add','restrictive_security_opt','deploy_devices','empty_deploy_devices']:
        before_calls = len(dockerlog.read_text().splitlines())
        run([stack,'up'],repo,dict(env,BAD_MODEL=bad),2)
        rejected_calls = [json.loads(line) for line in dockerlog.read_text().splitlines()[before_calls:]]
        assert not any('up' in call or 'stop' in call or 'exec' in call for call in rejected_calls)
        ok('negative unsafe model: '+bad)
    run([stack,'up'],repo,dict(env,REMOTE='1'),3)
    run([stack,'up'],repo,dict(env,DOCKER_HOST='unix:///override'),3)
    run([stack,'up'],repo,dict(env,MISSING_IMAGE='1'),3)
    run([stack,'doctor'],repo,dict(env,FAIL_DAEMON='1'),3)
    ok('negative remote endpoint, host override, missing image and daemon failure')
    with socket.socket() as listener:
        listener.bind(('127.0.0.1',0)); listener.listen()
        adapter['host_port']=listener.getsockname()[1]; configure()
        run([stack,'up'],repo,env,3,'port is occupied')
    adapter['host_port']=54000; configure()
    run([stack,'up'],repo,dict(env,APP_STATE='running',WRONG_OWNER='1'),3,'ownership mismatch')
    run([stack,'up'],repo,dict(env,APP_STATE='running',CONFIG_HASH='stale'),3,'configuration changed')
    run([stack,'up'],repo,dict(env,APP_STATE='running',HEALTH='unhealthy'),3,'unhealthy')
    ok('negative occupied port, foreign owner, stale config and unhealthy app')
    run([stack,'up'],repo,dict(env,FAIL_UP='1'),4,'no automatic cleanup')
    run([stack,'up'],repo,env,text='app running/healthy')
    run([stack,'up'],repo,dict(env,APP_STATE='running'))
    ok('up isolates app and retains resources on failure')
    output=run([stack,'status','--repo',repo],base,dict(env,APP_STATE='running'),text='app=running')
    project=output.splitlines()[0].split('=',1)[1]
    lock=repo/'.git'/('ej-'+project.rsplit('-',1)[1]+'.lock'); lock.mkdir()
    run([stack,'up'],repo,env,3,'workspace is locked'); lock.rmdir()
    ok('status scoping and lifecycle lock refusal')
    run([stack,'verify','full'],repo,env,3,'running owned app')
    run([stack,'verify','fast'],repo,dict(env,APP_STATE='running',VERIFY_EXIT='7'),7)
    ok('verify requires running app; preserves gate exit')
    run([stack,'down'],repo,dict(env,APP_STATE='running',MISSING_IMAGE='1',CONFIG_HASH='stale'),text='databases retained')
    run([stack,'down'],repo,dict(env,APP_STATE='exited'))
    ok('down stops only app; repeated stop harmless; image not required')
    sibling=base/'sibling worktree'
    run(['git','worktree','add','--quiet','--detach',str(sibling)],repo)
    (sibling/'.elixir-journey').mkdir()
    shutil.copy2(repo/'.elixir-journey/stack.json',sibling/'.elixir-journey/stack.json')
    shutil.copy2(repo/'compose.agent.yaml',sibling/'compose.agent.yaml')
    assert run([stack,'status'],sibling,env).splitlines()[0]!=output.splitlines()[0]
    ok('linked worktrees have distinct identities')
    calls=[json.loads(line) for line in dockerlog.read_text().splitlines()]
    assert not any(any(word in call for word in ['prune','rm','down','build','run']) for call in calls)
    up=next(call for call in calls if 'up' in call)
    assert all(flag in up for flag in ['--no-deps','--no-build','--no-recreate','--wait'])
    assert all(call[call.index('--pull')+1]=='never' for call in calls if '--pull' in call)
    assert all(call[-1]=='app' for call in calls if 'stop' in call)
    assert all(call[call.index('--env-file')+1]==os.devnull for call in calls if call[0]=='compose')
    ok('recorded Docker calls exclude global/destructive actions and implicit .env')
print(str(count)+' contract cases passed; Docker was faked throughout.')
PYTHON
