#!/usr/bin/env python3
"""Preparation supervisor; exec the matrix once the true-size Twitter cohort exists."""
import datetime
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    directory = Path(sys.argv[1]).resolve()
    scripts = directory/'runner'
    root = Path(os.environ.get('CG_STAGE_ROOT', Path(__file__).resolve().parents[1])).resolve()
    os.environ.update(CG_STAGE_ROOT=str(root), CG_STAGE_TWITTER=str(directory/'twitter_true'),
                      CG_STAGE_REMAPPER=str(scripts/'remap_twitter_vertex_ids.py'))
    lock = (directory/'supervisor.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    with (directory/'runner.lock').open('a') as active:
        fcntl.flock(active, fcntl.LOCK_EX | fcntl.LOCK_NB)
    def status(state, **extra):
        p = directory/'status.json'
        tmp = directory/'status.json.tmp'
        tmp.write_text(json.dumps({'state': state, 'pid': os.getpid(),
            'updated_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), **extra}, indent=2)+'\n')
        tmp.replace(p)
    status('preparing_twitter', log=str(directory/'twitter_prepare.log'))
    with (directory/'twitter_prepare.log').open('a') as log:
        rc = subprocess.call([sys.executable, str(scripts/'prepare_stage_twitter.py'), str(directory/'twitter_true')],
                             stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
    if rc:
        status('failed_preparation', returncode=rc)
        return rc
    status('starting_matrix')
    os.execv(sys.executable, [sys.executable, '-u', str(scripts/'run_stage_pre_i17c.py'), str(directory)])


if __name__ == '__main__':
    sys.exit(main())
