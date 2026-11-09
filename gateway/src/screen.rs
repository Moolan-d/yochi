//! A terminal's screen as styled text, for the app to find the Agent's dialogs
//! in (ADR 0005). The Gateway attaches read-only, keeps the screen with
//! `vt100`, and renders it the way a screen read reads: one row per line,
//! CRLF between rows, SGR for the styling and nothing else.

use std::fmt::Write as _;
use std::num::NonZero;
use vt100::{Cell, Color, Parser};

/// The styling a dialog parser reads meaning from; the rest is dropped.
#[derive(Clone, Copy, PartialEq, Default)]
struct Style {
    foreground: Option<Color>,
    background: Option<Color>,
    bold: bool,
    dim: bool,
    italic: bool,
    reverse: bool,
}

impl Style {
    fn of(cell: &Cell) -> Self {
        let color = |color| (color != Color::Default).then_some(color);
        Style {
            foreground: color(cell.fgcolor()),
            background: color(cell.bgcolor()),
            bold: cell.bold(),
            dim: cell.dim(),
            italic: cell.italic(),
            reverse: cell.inverse(),
        }
    }

    /// `ESC[0;…m`: every change starts from a reset, so no row depends on
    /// the one before it.
    fn sgr(self) -> String {
        let mut codes = vec!["0".to_owned()];
        if self.bold {
            codes.push("1".into());
        }
        if self.dim {
            codes.push("2".into());
        }
        if self.italic {
            codes.push("3".into());
        }
        if self.reverse {
            codes.push("7".into());
        }
        let mut color = |base: u8, color: Option<Color>| match color {
            Some(Color::Idx(index)) => codes.push(format!("{base};5;{index}")),
            Some(Color::Rgb(r, g, b)) => codes.push(format!("{base};2;{r};{g};{b}")),
            Some(Color::Default) | None => {}
        };
        color(38, self.foreground);
        color(48, self.background);
        format!("\x1b[{}m", codes.join(";"))
    }
}

pub struct Screen {
    parser: Parser,
}

impl Screen {
    pub fn new(cols: u16, rows: u16) -> Self {
        Screen { parser: Parser::new(nonzero(rows), nonzero(cols), 0) }
    }

    pub fn process(&mut self, bytes: &[u8]) {
        self.parser.process(bytes);
    }

    pub fn resize(&mut self, cols: u16, rows: u16) {
        self.parser.screen_mut().set_size(nonzero(rows), nonzero(cols));
    }

    /// The visible rows, styled. Trailing blanks without a background are
    /// left off; a cell under a wide character is skipped.
    pub fn render(&self) -> String {
        let screen = self.parser.screen();
        let (rows, cols) = screen.size();
        let mut out = String::new();
        for row in 0..rows.get() {
            if row > 0 {
                out.push_str("\r\n");
            }
            let cells: Vec<&Cell> = (0..cols.get()).filter_map(|col| screen.cell(row, col)).collect();
            let end = cells
                .iter()
                .rposition(|cell| cell.has_contents() || Style::of(cell).background.is_some() || Style::of(cell).reverse)
                .map_or(0, |last| last + 1);
            let mut style = Style::default();
            for cell in &cells[..end] {
                if cell.is_wide_continuation() {
                    continue;
                }
                let next = Style::of(cell);
                if next != style {
                    out.push_str(&next.sgr());
                    style = next;
                }
                if cell.has_contents() {
                    out.push_str(cell.contents());
                } else {
                    out.push(' ');
                }
            }
            if style != Style::default() {
                out.push_str("\x1b[0m");
            }
        }
        out
    }

    /// Row and column of the cursor, zero-based; None while it is hidden.
    pub fn cursor(&self) -> Option<(u16, u16)> {
        let screen = self.parser.screen();
        (!screen.hide_cursor()).then(|| screen.cursor_position())
    }
}

fn nonzero(n: u16) -> NonZero<u16> {
    NonZero::new(n).unwrap_or(NonZero::<u16>::MIN)
}

/// The rendered text without styling.
pub fn plain(rendered: &str) -> String {
    let mut out = String::new();
    let mut chars = rendered.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
            continue;
        }
        let _ = out.write_char(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_rows_with_their_styling() {
        let mut screen = Screen::new(20, 4);
        screen.process(b"\x1b[H\x1b[2J\x1b[1m\x1b[38;2;177;185;249mTitle\x1b[0m\r\n");
        screen.process(b" \x1b[38;5;8m1.\x1b[0m Yes\r\n\x1b[7m \x1b[0m");
        let rendered = screen.render();
        let rows: Vec<&str> = rendered.split("\r\n").collect();
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0], "\x1b[0;1;38;2;177;185;249mTitle\x1b[0m");
        assert_eq!(rows[1], " \x1b[0;38;5;8m1.\x1b[0m Yes");
        // A reverse-video blank is the text cursor a dialog field draws.
        assert_eq!(rows[2], "\x1b[0;7m \x1b[0m");
        assert_eq!(rows[3], "");
        assert_eq!(plain(&rendered), "Title\r\n 1. Yes\r\n \r\n");
    }

    #[test]
    fn wide_characters_take_one_glyph() {
        let mut screen = Screen::new(10, 1);
        screen.process("中文 ok".as_bytes());
        assert_eq!(screen.render(), "中文 ok");
    }

    #[test]
    fn cursor_is_reported_only_when_shown() {
        let mut screen = Screen::new(10, 3);
        screen.process(b"\x1b[2;4H");
        assert_eq!(screen.cursor(), Some((1, 3)));
        screen.process(b"\x1b[?25l");
        assert_eq!(screen.cursor(), None);
    }

    #[test]
    fn resizing_keeps_the_screen() {
        let mut screen = Screen::new(10, 2);
        screen.process(b"hello");
        screen.resize(20, 3);
        assert_eq!(plain(&screen.render()), "hello\r\n\r\n");
    }
}
