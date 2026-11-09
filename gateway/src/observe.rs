//! A view of one terminal: its own framed `hc connect`, then `terminal.attach`.
//! Observing never types into or resizes the terminal. Taking it over sets
//! its size to the phone's while attached; core gives the size back to the
//! desktop once the phone detaches. A takeover may also type: while the phone
//! sets the terminal's size it is the terminal's keyboard, and its keystrokes
//! and mouse-wheel scrolls go to the program.

use anyhow::{Context as _, Result, anyhow, bail};
use serde_json::{Value, json};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::mpsc;

const DATA: u8 = 0;
const CREDIT: u8 = 1;
const CLOSE: u8 = 2;
const RESIZE: u8 = 3;
const HEADER: usize = 9;
/// Scrollback the terminal page's first paint carries, so it can scroll back a little.
pub const HISTORY: u32 = 1000;

pub enum Output {
    /// The terminal's bytes: first paint, then the program's raw output.
    Data(Vec<u8>),
    /// The core ended the stream; the reason as the core gave it (e.g. `exited`).
    Closed(Value),
}

pub struct Observer {
    /// The attached terminal's record as of attaching.
    pub terminal: Value,
    channel: u32,
    stdin: ChildStdin,
    output: mpsc::Receiver<Output>,
    /// Bytes that arrived before the attach reply.
    early: Vec<Output>,
    _child: Child,
}

enum Frame {
    Reply(Value),
    Stream(u8, Vec<u8>),
}

impl Observer {
    pub async fn attach(hc: &str, terminal: &str, cols: u16, rows: u16, history: u32, observe: bool) -> Result<Self> {
        let mut child = Command::new(hc)
            .arg("connect")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .with_context(|| format!("starting `{hc} connect`"))?;
        let mut stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
        let mut stdout = BufReader::new(child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?);

        // The hello reply is still a plain line; frames follow it.
        stdin.write_all(b"{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"hello\",\"params\":{\"framed\":true}}\n").await?;
        let mut line = String::new();
        stdout.read_line(&mut line).await?;
        let hello: Value = serde_json::from_str(&line).context("bad hello reply from core")?;
        if let Some(error) = hello.get("error") {
            bail!("core refused hello: {error}");
        }

        let request = json!({"jsonrpc": "2.0", "id": 1, "method": "terminal.attach", "params": {
            // An observer's size is only bookkeeping; a takeover viewer's is the
            // terminal's new size while it is the most recently attached viewer.
            "terminal": terminal, "cols": cols, "rows": rows, "observe": observe, "history": history,
        }});
        write_frame(&mut stdin, 0, DATA, request.to_string().as_bytes()).await?;

        let (frames_tx, mut frames) = mpsc::channel(64);
        tokio::spawn(read_frames(stdout, frames_tx));

        let mut early = Vec::new();
        let reply = tokio::time::timeout(Duration::from_secs(10), async {
            while let Some(frame) = frames.recv().await {
                match frame {
                    Frame::Reply(reply) => return Ok(reply),
                    Frame::Stream(kind, payload) => early.extend(output(kind, payload)),
                }
            }
            bail!("core closed the connection while attaching")
        })
        .await
        .context("no attach reply from core")??;
        if let Some(error) = reply.get("error") {
            bail!("{}", error["message"].as_str().unwrap_or("attach refused"));
        }
        let result = &reply["result"];
        let channel = result["channel"].as_u64().ok_or_else(|| anyhow!("attach returned no channel"))? as u32;

        // Only one stream rides this connection; turn its frames into Output.
        let (output_tx, output_rx) = mpsc::channel(64);
        tokio::spawn(async move {
            while let Some(frame) = frames.recv().await {
                if let Frame::Stream(kind, payload) = frame
                    && let Some(item) = output(kind, payload)
                    && output_tx.send(item).await.is_err()
                {
                    return;
                }
            }
            let _ = output_tx.send(Output::Closed(json!({"reason": "core_lost"}))).await;
        });

        Ok(Observer { terminal: result["terminal"].clone(), channel, stdin, output: output_rx, early, _child: child })
    }

    /// The next piece of output, early bytes first. None once nothing more can come.
    pub async fn next(&mut self) -> Option<Output> {
        if !self.early.is_empty() {
            return Some(self.early.remove(0));
        }
        self.output.recv().await
    }

    /// Tells the core these bytes were written out, so it keeps sending.
    pub async fn consumed(&mut self, bytes: usize) -> Result<()> {
        write_frame(&mut self.stdin, self.channel, CREDIT, &(bytes as u32).to_le_bytes()).await
    }

    /// A takeover viewer's new size, e.g. the phone's keyboard came up.
    pub async fn resize(&mut self, cols: u16, rows: u16) -> Result<()> {
        write_frame(&mut self.stdin, self.channel, RESIZE, &resize_payload(cols, rows)).await
    }

    /// A takeover viewer's scroll, as wheel reports the program asked for
    /// (see `wheel_only`). Anything else is refused, so the phone never types.
    pub async fn wheel(&mut self, reports: &[u8]) -> Result<()> {
        if !wheel_only(reports) {
            bail!("not only wheel reports");
        }
        write_frame(&mut self.stdin, self.channel, DATA, reports).await
    }

    /// A takeover viewer's keystrokes, as the phone's terminal encoded them.
    pub async fn input(&mut self, bytes: &[u8]) -> Result<()> {
        if !valid_input(bytes) {
            bail!("no input, or too much at once");
        }
        write_frame(&mut self.stdin, self.channel, DATA, bytes).await
    }

    pub async fn detach(mut self) {
        let _ = write_frame(&mut self.stdin, self.channel, CLOSE, &[]).await;
    }
}

/// Core's RESIZE frame: columns then rows, little-endian u16 each.
fn resize_payload(cols: u16, rows: u16) -> [u8; 4] {
    let [c0, c1] = cols.to_le_bytes();
    let [r0, r1] = rows.to_le_bytes();
    [c0, c1, r0, r1]
}

/// Most the app types at once: a paste, or keys queued while the link was slow.
const INPUT_MAX: usize = 64 * 1024;

/// Whether `bytes` can go to the terminal as typed input.
pub fn valid_input(bytes: &[u8]) -> bool {
    !bytes.is_empty() && bytes.len() <= INPUT_MAX
}

/// Longest scroll the app sends at once; a fling sends many in a row.
const WHEEL_MAX: usize = 4096;

/// Whether `bytes` are nothing but what a terminal sends for a scroll: SGR
/// mouse wheel reports (`ESC [ < b ; x ; y M`, b 64–67 plus shift, meta or
/// ctrl), or the cursor up and down keys a terminal sends instead on the
/// alternate screen when the program doesn't report the mouse.
pub fn wheel_only(bytes: &[u8]) -> bool {
    if bytes.is_empty() || bytes.len() > WHEEL_MAX {
        return false;
    }
    let mut rest = bytes;
    while !rest.is_empty() {
        match wheel_report(rest) {
            Some(len) => rest = &rest[len..],
            None => return false,
        }
    }
    true
}

/// The length of the wheel report or scroll key `bytes` start with.
fn wheel_report(bytes: &[u8]) -> Option<usize> {
    match bytes {
        [0x1b, b'[' | b'O', b'A' | b'B', ..] => Some(3),
        [0x1b, b'[', b'<', rest @ ..] => {
            let mut fields = [0u32; 3];
            let mut at = 0;
            for (i, field) in fields.iter_mut().enumerate() {
                let digits = rest[at..].iter().take_while(|b| b.is_ascii_digit()).count();
                if digits == 0 || digits > 4 {
                    return None;
                }
                *field = std::str::from_utf8(&rest[at..at + digits]).ok()?.parse().ok()?;
                at += digits;
                let end = if i < 2 { b';' } else { b'M' };
                if rest.get(at) != Some(&end) {
                    return None;
                }
                at += 1;
            }
            // Shift, meta and ctrl ride in bits 2–4; 64–67 is the wheel.
            (64..=67).contains(&(fields[0] & !0b11100)).then_some(3 + at)
        }
        _ => None,
    }
}

fn output(kind: u8, payload: Vec<u8>) -> Option<Output> {
    match kind {
        DATA => Some(Output::Data(payload)),
        CLOSE => Some(Output::Closed(serde_json::from_slice(&payload).unwrap_or(Value::Null))),
        _ => None,
    }
}

async fn read_frames(mut stdout: BufReader<ChildStdout>, frames: mpsc::Sender<Frame>) {
    let mut header = [0u8; HEADER];
    loop {
        if stdout.read_exact(&mut header).await.is_err() {
            return;
        }
        let channel = u32::from_le_bytes(header[0..4].try_into().unwrap());
        let kind = header[4];
        let len = u32::from_le_bytes(header[5..9].try_into().unwrap()) as usize;
        let mut payload = vec![0; len];
        if stdout.read_exact(&mut payload).await.is_err() {
            return;
        }
        let frame = if channel == 0 {
            match serde_json::from_slice(&payload) {
                Ok(message) => Frame::Reply(message),
                Err(_) => continue,
            }
        } else {
            Frame::Stream(kind, payload)
        };
        if frames.send(frame).await.is_err() {
            return;
        }
    }
}

async fn write_frame(stdin: &mut ChildStdin, channel: u32, kind: u8, payload: &[u8]) -> Result<()> {
    let mut frame = Vec::with_capacity(HEADER + payload.len());
    frame.extend(channel.to_le_bytes());
    frame.push(kind);
    frame.extend((payload.len() as u32).to_le_bytes());
    frame.extend(payload);
    stdin.write_all(&frame).await?;
    stdin.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_wheel_reports_pass() {
        assert!(wheel_only(b"\x1b[<64;10;5M"));
        assert!(wheel_only(b"\x1b[<65;1;1M\x1b[<65;1;1M\x1b[<69;300;40M"));
        assert!(wheel_only(b"\x1b[A\x1b[B\x1bOA\x1bOB"));
        // Clicks, releases, motion, typing and partial reports are refused.
        assert!(!wheel_only(b""));
        assert!(!wheel_only(b"\x1b[<0;10;5M"));
        assert!(!wheel_only(b"\x1b[<0;10;5m"));
        assert!(!wheel_only(b"\x1b[<35;10;5M"));
        assert!(!wheel_only(b"\x1b[<64;10;5m"));
        assert!(!wheel_only(b"\x1b[<64;10;5"));
        assert!(!wheel_only(b"\x1b[<64;10M"));
        assert!(!wheel_only(b"\x1b[<64;;5M"));
        assert!(!wheel_only(b"\x1b[<64;10;5Mls\r"));
        assert!(!wheel_only(b"\x1b[C"));
        assert!(!wheel_only(b"\x1b[M`!!"));
        assert!(!wheel_only(&b"\x1b[A".repeat(2000)));
    }

    #[test]
    fn input_is_anything_typed_within_bounds() {
        assert!(valid_input(b"ls\t"));
        assert!(valid_input(b"\x03"));
        assert!(valid_input(&[b'a'; INPUT_MAX]));
        assert!(!valid_input(b""));
        assert!(!valid_input(&[b'a'; INPUT_MAX + 1]));
    }

    #[test]
    fn resize_payload_is_cols_then_rows() {
        assert_eq!(resize_payload(60, 30), [60, 0, 30, 0]);
        assert_eq!(resize_payload(300, 1), [44, 1, 1, 0]);
    }
}
