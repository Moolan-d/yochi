//! The reply Claude Code is writing, read off its screen. Its transcript gets
//! a text block only once the block is complete, so until then the screen is
//! the only place the words are. Claude Code draws a reply as a block that
//! starts with `⏺ ` and goes on indented by two columns, above the rule over
//! its input box; tool calls and the user's prompt start differently, so a
//! screen whose last block isn't a reply has no draft.

use crate::observe::{Observer, Output};
use crate::screen::{self, Screen};
use anyhow::Result;
use unicode_width::UnicodeWidthStr;

/// A read-only attach to the terminal, kept while the Agent works, with the
/// screen it draws.
pub struct Reader {
    observer: Observer,
    screen: Screen,
    size: (u16, u16),
    /// Output arrived since the draft was last read.
    changed: bool,
}

impl Reader {
    pub async fn attach(hc: &str, terminal: &str, (cols, rows): (u16, u16)) -> Result<Self> {
        let observer = Observer::attach(hc, terminal, cols, rows, 0, true).await?;
        let grid = |key: &str, default: u16| {
            observer.terminal[key].as_u64().and_then(|n| u16::try_from(n).ok()).unwrap_or(default)
        };
        let (cols, rows) = (grid("cols", cols), grid("rows", rows));
        Ok(Reader { observer, screen: Screen::new(cols, rows), size: (cols, rows), changed: true })
    }

    /// Takes in the next output; false once the stream has ended.
    pub async fn read(&mut self) -> bool {
        match self.observer.next().await {
            Some(Output::Data(bytes)) => {
                self.screen.process(&bytes);
                self.changed = true;
                self.observer.consumed(bytes.len()).await.is_ok()
            }
            Some(Output::Closed(_)) | None => false,
        }
    }

    pub fn resize(&mut self, size: (u16, u16)) {
        if size != self.size {
            self.size = size;
            self.screen.resize(size.0, size.1);
            self.changed = true;
        }
    }

    /// Read the draft again at the next chance, changed or not.
    pub fn touch(&mut self) {
        self.changed = true;
    }

    /// The draft, if the screen changed since it was last asked.
    pub fn draft(&mut self) -> Option<Option<String>> {
        if !std::mem::take(&mut self.changed) {
            return None;
        }
        Some(draft(&screen::plain(&self.screen.render()), self.size.0))
    }

    pub async fn detach(self) {
        self.observer.detach().await;
    }
}

/// The most of a draft that is sent: its end, which is what is changing.
pub const MAX_CHARS: usize = 1500;

/// The reply being written on this screen (plain text, one row per line), or
/// None when the screen's last block is something else: its last
/// `MAX_CHARS`, and only what is still on screen once its start scrolled off.
pub fn draft(screen: &str, cols: u16) -> Option<String> {
    reply(screen, cols).map(|text| tail(&text))
}

/// All of the reply on screen.
fn reply(screen: &str, cols: u16) -> Option<String> {
    let rows: Vec<&str> = screen.lines().map(|row| row.trim_end_matches(['\r', ' '])).collect();
    // The input box sits between two rules; the reply is above the upper one.
    let mut rules = rows.iter().enumerate().rev().filter(|(_, row)| is_rule(row)).map(|(i, _)| i);
    let _lower = rules.next()?;
    let upper = rules.next()?;

    let mut end = upper;
    // While it thinks, a spinner line (and maybe its to-dos) sits under the reply.
    if let Some(head) = (0..upper).rev().find(|&i| starts_block(rows[i]))
        && is_spinner(rows[head])
    {
        end = head;
    }
    let mut start = end;
    while start > 0 {
        let row = rows[start - 1];
        if starts_block(row) {
            let rest = row.strip_prefix("⏺ ")?;
            let mut body = vec![format!("  {rest}")];
            body.extend(rows[start..end].iter().map(|row| (*row).to_owned()));
            return finish(&body, cols);
        }
        start -= 1;
    }
    // Its start scrolled off the top: what is left of it.
    let body: Vec<String> = rows[..end].iter().map(|row| (*row).to_owned()).collect();
    finish(&body, cols)
}

/// A row that begins a block: anything not indented.
fn starts_block(row: &str) -> bool {
    row.chars().next().is_some_and(|c| !c.is_whitespace())
}

/// Claude Code's spinner or its "done" line: a glyph, a space, then words.
fn is_spinner(row: &str) -> bool {
    let mut chars = row.chars();
    matches!(chars.next(), Some(c) if c != '⏺' && c != '❯' && !c.is_alphanumeric()) && chars.next() == Some(' ')
}

fn is_rule(row: &str) -> bool {
    row.chars().count() >= 8 && row.chars().all(|c| c == '─')
}

/// Drops the reply's two-column indent, joins the rows Claude Code wrapped,
/// and keeps the end if it is long.
fn finish(rows: &[String], cols: u16) -> Option<String> {
    let width = usize::from(cols).saturating_sub(2);
    let mut lines: Vec<String> = Vec::new();
    // Whether the last line was wrapped onto the next row.
    let mut open = false;
    for row in rows {
        let text = row.strip_prefix("  ").unwrap_or(row.trim_start());
        if text.trim().is_empty() {
            lines.push(String::new());
            open = false;
            continue;
        }
        let wrapped_into = open && !starts_item(text);
        let last_row_width = row.width();
        if wrapped_into {
            let line = lines.last_mut().expect("open line");
            let next = text.trim_start();
            if !(ends_wide(line) && starts_wide(next)) {
                line.push(' ');
            }
            line.push_str(next);
        } else {
            lines.push(text.to_owned());
        }
        // Wrapped if the next row's first word could not have fit on this one.
        open = last_row_width + 1 + MIN_WORD > width;
    }
    while lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    while lines.first().is_some_and(String::is_empty) {
        lines.remove(0);
    }
    let text = lines.join("\n");
    if text.trim().is_empty() {
        return None;
    }
    Some(text)
}

/// A row is taken as wrapped when it ends this close to the edge; a word
/// shorter than this would have fit.
const MIN_WORD: usize = 8;

/// A list item or other line that starts on its own rather than continuing.
fn starts_item(text: &str) -> bool {
    let trimmed = text.trim_start();
    trimmed.starts_with("- ")
        || trimmed.starts_with("* ")
        || trimmed.starts_with("• ")
        || trimmed.split_once(". ").is_some_and(|(n, _)| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
}

fn starts_wide(text: &str) -> bool {
    text.chars().next().is_some_and(|c| c.to_string().width() == 2)
}

fn ends_wide(text: &str) -> bool {
    text.chars().last().is_some_and(|c| c.to_string().width() == 2)
}

/// The last `MAX_CHARS` characters, starting at a line if one is near.
fn tail(text: &str) -> String {
    let count = text.chars().count();
    if count <= MAX_CHARS {
        return text.to_owned();
    }
    let cut = text.char_indices().nth(count - MAX_CHARS).map_or(0, |(i, _)| i);
    let rest = &text[cut..];
    match rest.find('\n') {
        Some(newline) if newline < 200 => rest[newline + 1..].to_owned(),
        _ => rest.to_owned(),
    }
}

/// Letters and digits only, lowercased: what a draft and the Markdown it
/// becomes have in common.
fn letters(text: &str) -> String {
    text.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

/// Whether the transcript already holds this draft: the reply it shows is
/// `reply` (all of it, or its end), or `reply` and then a tool call drawn
/// under it.
pub fn recorded(draft: &str, reply: Option<&str>) -> bool {
    let Some(reply) = reply else { return false };
    let (draft, reply) = (letters(draft), letters(reply));
    !reply.is_empty() && !draft.is_empty() && (reply.contains(&draft) || draft.starts_with(&reply))
}

#[cfg(test)]
mod tests {
    use super::*;

    const COLS: u16 = 200;

    fn fixture(name: &str) -> String {
        std::fs::read_to_string(format!("{}/tests/fixtures/draft/{name}.txt", env!("CARGO_MANIFEST_DIR"))).unwrap()
    }

    #[test]
    fn nothing_while_it_thinks() {
        assert_eq!(draft(&fixture("thinking"), COLS), None);
    }

    #[test]
    fn the_reply_as_it_is_written() {
        let text = reply(&fixture("writing"), COLS).unwrap();
        assert!(text.starts_with("How TCP Congestion Control Works\n\nWhen two computers exchange data"), "{text}");
        // Rows Claude Code wrapped are one line again.
        let paragraph = text.lines().nth(2).unwrap();
        assert!(paragraph.contains("each with limited capacity. If every sender"), "{paragraph}");
        assert!(paragraph.ends_with("adjust its sending rate to match."), "{paragraph}");
        // A list item starts its own line and keeps its continuation.
        assert!(text.lines().any(|line| line.starts_with("- Slow start:") && line.contains("roughly doubles")), "{text}");
        // The prompt above it and the input box below it are left out.
        assert!(!text.contains("Do not use any tools") && !text.contains('❯') && !text.contains('─'));
    }

    #[test]
    fn code_keeps_its_rows() {
        let text = draft(&fixture("code"), COLS).unwrap();
        assert!(text.contains("    else:\n        cwnd += 1"), "{text}");
        assert!(text.ends_with("print(f\"RTT {rtt:2d}: cwnd = {cwnd:5.1f}\")"), "{text}");
    }

    #[test]
    fn a_long_reply_is_cut_to_its_end() {
        let text = draft(&fixture("written"), COLS).unwrap();
        assert!(text.ends_with("do not push harder than it can carry."), "{text}");
        assert!(text.chars().count() <= MAX_CHARS);
        assert!(!text.starts_with("How TCP"));
    }

    #[test]
    fn a_reply_whose_start_scrolled_off() {
        let screen = fixture("writing");
        let rows: Vec<&str> = screen.lines().collect();
        let start = rows.iter().position(|row| row.starts_with("⏺")).unwrap();
        let scrolled = rows[start + 6..].join("\n");
        let text = reply(&scrolled, COLS).unwrap();
        assert!(text.starts_with("The central idea is the congestion window"), "{text}");
    }

    #[test]
    fn the_last_reply_after_a_tool_call() {
        let text = draft(&fixture("after-tool"), COLS).unwrap();
        assert!(text.starts_with("Running date shows it is"), "{text}");
        assert!(!text.contains("Ran 1 shell command"));
    }

    #[test]
    fn wide_characters_join_without_a_space() {
        let wide = "字".repeat(99);
        let screen = format!("❯ 你好\n⏺ {wide}\n  还有一行\n{rule}\n❯ \n{rule}\n", rule = "─".repeat(40));
        assert_eq!(draft(&screen, COLS).unwrap(), format!("{wide}还有一行"));
    }

    #[test]
    fn short_rows_are_their_own_lines() {
        let screen = format!("⏺ First line\n  second line\n{rule}\n❯ \n{rule}\n", rule = "─".repeat(40));
        assert_eq!(draft(&screen, COLS).unwrap(), "First line\nsecond line");
    }

    #[test]
    fn no_input_box_no_draft() {
        assert_eq!(draft("⏺ Hello", COLS), None);
    }

    #[test]
    fn recorded_once_the_transcript_has_it() {
        let reply = "## Heading\n\nSome **bold** text, then `code`.";
        assert!(recorded("Heading\n\nSome bold text, then code.", Some(reply)));
        assert!(recorded("bold text, then code.", Some(reply)));
        assert!(recorded("Heading Some bold text, then code. Ran 1 shell command", Some(reply)));
        assert!(!recorded("Heading Some bold", Some("Something else")));
        assert!(!recorded("Anything", None));
    }
}
