import hashlib, os, subprocess, sys
from pathlib import Path
roots=('runtime/', 'server/', 'install/', 'app/', 'dev/')
files=subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard']).split(b'\0')
paths=set()
for raw in files:
 if not raw: continue
 p=os.fsdecode(raw)
 if not (p.startswith(roots) or p in ('Makefile','makefile','GNUmakefile','pyproject.toml','uv.lock','requirements.txt','CMakeLists.txt')): continue
 if any(part in {'build','.build','__pycache__','.ruff_cache','.venv','models','agents','profiles','evidence'} for part in Path(p).parts): continue
 if p.endswith(('.pyc','.log')) or not Path(p).is_file(): continue
 paths.add(p)
with open(sys.argv[1], 'w') as out:
 for p in sorted(paths, key=os.fsencode):
  out.write(hashlib.sha256(Path(p).read_bytes()).hexdigest()+'  '+p+'\n')
print(len(paths), hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
