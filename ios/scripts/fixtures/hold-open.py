"""Stands in for an Agent in the UI tests: a process that holds a session
file open, as pi does, so the Gateway finds it. Usage:
hold-open.py <session file>"""
import sys
import time

rollout = open(sys.argv[1], "a")
while True:
    time.sleep(1)
