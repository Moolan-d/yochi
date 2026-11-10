# Fixtures

`screens/claude/*.ansi` are Claude Code screens captured by Heeler
(https://github.com/ZingerLittleBee/Heeler, Apache-2.0, at b9790d8) from live
probes against an isolated herdr backend, none from a personal session. Each
file is one visible-screen read: rows separated by CRLF, styled with SGR only,
which is also what the Gateway's `/v0/screen` sends.

`snapshots/claude/*.json` record what the corresponding `ClaudeDialogParser`
result puts on the phone, as sorted JSON: the dialog's kind, text, options,
focus and keys, or the generic card's lines. Styling, row ranges and
fingerprints are left out, so only a change a card would show moves them. `DialogFixtureTests` replays every capture and compares
it with its snapshot, so a parser change must be reviewed as a fixture diff
rather than checked by eye in the simulator. After an intentional change,
regenerate the snapshots from `ios/` with:

```sh
scripts/record-dialog-snapshots.sh
# or: SIM='iPhone 18 Pro Max' scripts/record-dialog-snapshots.sh
```

The script creates a temporary marker, runs only `DialogFixtureTests`, and
removes the marker on exit. Recording writes into the source tree; normal test
runs only read the bundled snapshots. Review the JSON changes before
committing them.
