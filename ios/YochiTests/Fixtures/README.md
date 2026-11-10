# Fixtures

`screens/claude/*.ansi` are Claude Code screens captured by Heeler
(https://github.com/ZingerLittleBee/Heeler, Apache-2.0, at b9790d8) from live
probes against an isolated herdr backend, none from a personal session. Each
file is one visible-screen read: rows separated by CRLF, styled with SGR only,
which is also what the Gateway's `/v0/screen` sends.
