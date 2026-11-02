//! A view of one terminal: its own framed `hc connect`, then `terminal.attach`.
//! Observing never types into or resizes the terminal; a takeover viewer sets
//! its size (and still never types), so a full-screen program redraws for the phone.

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
const HEADER: usize = 9;
/// Scrollback the first paint carries, so the app can scroll back a little.
const HISTORY: u32 = 1000;

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
    pub async fn attach(hc: &str, terminal: &str, cols: u16, rows: u16, observe: bool) -> Result<Self> {
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
            "terminal": terminal, "cols": cols, "rows": rows, "observe": observe, "history": HISTORY,
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

    pub async fn detach(mut self) {
        let _ = write_frame(&mut self.stdin, self.channel, CLOSE, &[]).await;
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
