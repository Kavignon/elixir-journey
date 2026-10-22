#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
exec python3 - "$root" <<'PYTHON'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
count = 0

def run(args, cwd):
    return subprocess.run([str(x) for x in args], cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

def require(args, cwd):
    p = run(args, cwd)
    if p.returncode: raise AssertionError(str(args)+'\n'+p.stdout)
    return p.stdout

def adopt(repo):
    (repo/'scripts').mkdir()
    shutil.copy2(source/'templates/elixir/scripts/verify.sh', repo/'scripts/verify.sh')
    require(['git','init','-q'],repo)
    require(['git','add','.'],repo)
    require(['git','-c','user.name=Harness','-c','user.email=harness@example.invalid','-c','commit.gpgsign=false','commit','-qm','audited disposable Mix fixture'],repo)

def snapshot(repo):
    files = subprocess.check_output(['git','ls-files','-z'],cwd=repo).split(b'\0')
    return {name:(repo/os.fsdecode(name)).read_bytes() for name in files if name}

def check(repo, mode, label, failure=None):
    global count
    before = snapshot(repo)
    p = run(['sh','scripts/verify.sh',mode],repo)
    assert snapshot(repo)==before, 'gate rewrote tracked fixture files'
    if failure:
        assert p.returncode != 0 and failure in p.stdout, label+'\n'+p.stdout
    else:
        assert p.returncode == 0, label+'\n'+p.stdout
    count += 1
    print('PASS '+label+'; command=sh scripts/verify.sh '+mode+'; gate exit='+str(p.returncode),flush=True)
    for line in p.stdout.splitlines():
        if line.startswith(('RUN','RESULT','Gate')): print('  '+line,flush=True)
    return p.stdout

print(require(['mix','--version'],source).strip(),flush=True)
with tempfile.TemporaryDirectory(prefix='ej-real-mix-') as temporary:
    base = Path(temporary)
    repo = base/'plain fixture'
    require(['mix','new',str(repo),'--app','harness_fixture','--module','HarnessFixture'],base)
    adopt(repo)
    check(repo,'fast','plain healthy fast')
    check(repo,'full','plain healthy full')
    lib = repo/'lib/harness_fixture.ex'; original = lib.read_text()
    lib.write_text(original+'\ndefmodule Unformatted do\ndef x,do: 1\nend\n')
    output = check(repo,'full','negative formatting failure without rewriting','not formatted')
    assert 'RUN env MIX_ENV=dev mix compile' not in output
    lib.write_text(original+'\ndefmodule WarningControl do\n  def value do\n    unused = 1\n    :ok\n  end\nend\n')
    output = check(repo,'full','negative compiler warning; tests never run','warning')
    assert 'RUN env MIX_ENV=test mix test' not in output
    lib.write_text(original)
    failing = repo/'test/negative_test.exs'
    failing.write_text('defmodule NegativeTest do\n  use ExUnit.Case\n\n  test "negative control" do\n    assert false\n  end\nend\n')
    check(repo,'full','negative real ExUnit failure','1 failure')
    failing.unlink()
    check(repo,'full','plain recovered full')
    umbrella = base/'umbrella fixture'
    require(['mix','new',str(umbrella),'--umbrella','--app','harness_umbrella'],base)
    require(['mix','new','apps/harness_child','--app','harness_child','--module','HarnessChild'],umbrella)
    adopt(umbrella)
    check(umbrella,'full','umbrella root compiles and tests child')
    lib = umbrella/'apps/harness_child/lib/harness_child.ex'
    lib.write_text(lib.read_text().replace(':world',':broken'))
    check(umbrella,'full','negative umbrella child behavior failure','1 failure')
print(str(count)+' real Mix cases passed; tracked fixture source unchanged by every gate run.',flush=True)
PYTHON
