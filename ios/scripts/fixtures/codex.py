"""Stands in for Codex in the UI tests: a process named codex that holds a
rollout file open, as Codex does, so the Gateway finds it. Usage:
codex.py <rollout file>"""
import sys
import time

rollout = open(sys.argv[1], "a")
while True:
    time.sleep(1)
