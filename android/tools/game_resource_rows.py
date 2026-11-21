# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Memo for static game rows already hashed by the Android pack writer."""

from hashlib import sha256
import json
from pathlib import Path
import re
import stat
import tempfile

SCHEMA = 1


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def file_identity(path):
    info = Path(path).stat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f'游戏资源不是普通文件：{path}')
    return [info.st_dev, info.st_ino, info.st_size, info.st_mode, info.st_mtime_ns, info.st_ctime_ns]


class GameResourceRows:
    """Look up by selected paths and file identity, independent of shader/module inputs."""

    def __init__(self, directory, files, selector):
        self.directory = Path(directory)
        self.sources = dict(files)
        self.identities = {name: file_identity(path) for name, path in files}
        self.input_key = sha256(encode([SCHEMA, selector, self.identities])).hexdigest()
        self.receipt = self.directory / (self.input_key + '.json')
        self.rows = {}
        self.hit = self.receipt.exists()
        if self.hit:
            self.read()

    def read(self):
        if self.receipt.is_symlink():
            raise ValueError('游戏资源缓存回执经过链接')
        record = json.loads(self.receipt.read_bytes())
        rows = record['rows']
        if (record['input'] != self.input_key or record['sha256'] != sha256(encode(rows)).hexdigest()
                or set(rows) != set(self.sources)):
            raise ValueError('游戏资源缓存回执身份或摘要不符')
        for name, row in rows.items():
            if row[0] != self.identities[name][2] or not re.fullmatch('[0-9a-f]{64}', row[1]):
                raise ValueError('游戏资源缓存行不符')
        self.rows = rows

    def tracked(self, name, path):
        return self.sources.get(name) == path

    def finish(self):
        if any(file_identity(path) != self.identities[name] for name, path in self.sources.items()):
            raise ValueError('打包期间游戏资源发生变化')
        if set(self.rows) != set(self.sources):
            raise ValueError('游戏资源缓存缺少选中路径')
        if self.hit:
            return
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        value = dict(input=self.input_key, sha256=sha256(encode(self.rows)).hexdigest(), rows=self.rows)
        with tempfile.NamedTemporaryFile(dir=self.directory, mode='wb', delete=False) as output:
            output.write(encode(value) + b'\n')
        Path(output.name).replace(self.receipt)
