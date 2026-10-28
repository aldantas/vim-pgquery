#!/usr/bin/env python3
"""Small psql protocol double: log each process/file and echo SQL as output."""
import json
import os
import shlex
import sys
import time


def record(value):
    with open(os.environ['PGQUERY_TEST_LOG'], 'a') as log:
        log.write(json.dumps(value) + '\n')


def include(path):
    record({'file': path, 'mode': oct(os.stat(path).st_mode & 0o777), 'pid': os.getpid()})
    with open(path) as source:
        sql = source.read()
    if 'SLOW' in sql:
        time.sleep(0.3)
    if 'DIE' in sql:
        sys.exit(7)
    print(sql, end='', flush=True)
    if 'ERROR' in sql:
        print('ERROR: simulated SQL failure', file=sys.stderr, flush=True)


record({'args': sys.argv[1:], 'pid': os.getpid()})
if '-f' in sys.argv:
    include(sys.argv[sys.argv.index('-f') + 1])
else:
    for line in sys.stdin:
        command = shlex.split(line)
        if command[0] == 'i':  # shlex consumes the meta-command backslash
            include(command[1])
        elif command[0] == 'echo':
            # Exercise channel buffering of a marker split across writes.
            marker = command[1]
            sys.stdout.write(marker[:8])
            sys.stdout.flush()
            time.sleep(0.01)
            print(marker[8:], flush=True)
        elif command[0] == 'q':
            break
