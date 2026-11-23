# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Observe DSH activity without writing heartbeats inside the watchdog's child tree."""
import json
import importlib.util
from functools import lru_cache
from pathlib import Path
import time


@lru_cache(maxsize=4)
def process_tree(engine):
    # Reuse the watchdog's existing macOS/POSIX and Windows Toolhelp enumeration.
    path = Path(engine) / 'tools/nostall.py'
    spec = importlib.util.spec_from_file_location('s2arm_activity_processes', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.tree


class BatchActivity:
    def __init__(self, interval=10, engine=None, tree=None, alive=None):
        self.interval = interval
        self.engine = engine or Path(__file__).resolve().parents[2]
        self.tree = tree
        self.alive = alive
        self.clear()

    def clear(self):
        self.data = None
        self.last_emit = float('-inf')
        self.last_sample = float('-inf')
        self.in_flight = None

    def accept(self, line):
        if not line.startswith('#dsh_activity\t'):
            return
        try:
            data = json.loads(line.split('\t', 1)[1])
            if not isinstance(data, dict) or type(data.get('schema')) is not int or data['schema'] != 1:
                return
            if any(type(data.get(k)) is not int for k in ['pid', 'target', 'pool']):
                return
            if (data['pid'] <= 0 or data['target'] <= 0 or data['pool'] < data['target']
                    or not isinstance(data.get('stage'), str) or not data['stage'].startswith('直连库·')  # 非玩家句
                    or data.get('state') not in ['active', 'ended']):
                return
        except (ValueError, TypeError):
            return
        if data['state'] == 'ended':
            if self.data and data['pid'] == self.data['pid'] and data['stage'] == self.data['stage']:
                self.clear()
            return
        value = {k: data[k] for k in ['stage', 'pid', 'target', 'pool']}
        if not self.data or (value['pid'], value['stage']) != (self.data['pid'], self.data['stage']):
            self.last_emit = float('-inf')
            self.last_sample = float('-inf')
        self.data = value

    def due(self):
        return self.data is not None and time.monotonic() - self.last_emit >= self.interval

    def sent(self):
        self.last_emit = time.monotonic()

    def snapshot(self):
        if self.data is None:
            return None
        if time.monotonic() - self.last_sample >= self.interval:
            self.last_sample = time.monotonic()
            try:
                rows = (self.tree or process_tree(self.engine))(self.data['pid'])
                if not rows.get(self.data['pid'], (0, ''))[1]:
                    # Enumeration failure also yields an empty root. Only an independent
                    # liveness check can turn missing telemetry into an ended phase.
                    if self.alive and not self.alive(self.data['pid']):
                        self.clear()
                        return None
                    self.in_flight = None
                else:
                    names = [str(value[1]).lower().removesuffix('.exe') for value in rows.values()]
                    self.in_flight = sum(name in ['metal', 'metallib'] for name in names)
            except Exception:   # 进度采样只是遥测：任何读不到（含 ctypes 参数错，D-TW4Z）都按「未知」，绝不打断出包
                self.in_flight = None  # Unavailable is not a measured zero.
        return self.data | {'inFlight': self.in_flight}

    @staticmethod
    def describe(data):
        active = data['inFlight'] if data['inFlight'] is not None else '未知'  # 非玩家句
        return f"目标 {data['target']} · 任务池 {data['pool']} · Metal 进程（采样）{active}"
