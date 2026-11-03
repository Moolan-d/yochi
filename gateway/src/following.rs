//! Follows one terminal's conversation for one phone: finds the transcript
//! the foreground Claude Code is writing, re-checks it every tick (a new
//! session id after `/clear`, a new process after a restart), and turns new
//! lines and core status into updates for the app.

use crate::conversation::{Conversation, Item, Pending};
use crate::core::Client;
use crate::session::Session;
use crate::transcript::{self, Located, Tail};
use anyhow::Result;

pub enum Update {
    /// Start over with these items; `supported: false` means terminal view only.
    Conversation { supported: bool, items: Vec<Item> },
    /// Items added or changed since the last update.
    Items(Vec<Item>),
    Pending(Option<Pending>),
    /// The permission mode as of the Agent's latest message.
    Mode(String),
}

#[derive(Default)]
pub struct Follower {
    following: Option<(Located, Tail)>,
    conversation: Conversation,
    /// What the app was last told, so ticks only send changes.
    supported: Option<bool>,
    pending: Option<Pending>,
    mode: Option<String>,
}

impl Follower {
    pub async fn tick(&mut self, client: &mut Client, session: &Session) -> Result<Vec<Update>> {
        let machine = session.machine.as_deref();
        let located = match session.pid {
            Some(pid) => transcript::locate(client, machine, pid).await?,
            None => None,
        };
        let mut updates = Vec::new();
        let Some(located) = located else {
            self.following = None;
            self.conversation = Conversation::default();
            self.mode = None;
            if self.supported != Some(false) {
                self.supported = Some(false);
                updates.push(Update::Conversation { supported: false, items: Vec::new() });
            }
            self.pending_update(session, &mut updates);
            return Ok(updates);
        };

        let fresh = self.following.as_ref().is_none_or(|(current, _)| *current != located);
        let lines = if fresh {
            let mut tail = Tail::new(machine, &located);
            let lines = tail.start(client).await?;
            self.following = Some((located, tail));
            self.conversation = Conversation::default();
            lines
        } else {
            let (_, tail) = self.following.as_mut().expect("following");
            match tail.more(client).await {
                Ok(lines) => lines,
                Err(err) => {
                    // Rewritten under us: start over on the next tick.
                    eprintln!("conversation: {err:#}");
                    self.following = None;
                    return Ok(updates);
                }
            }
        };
        let changed = self.conversation.apply(lines.iter().map(String::as_str));
        if fresh {
            self.supported = Some(true);
            updates.push(Update::Conversation { supported: true, items: self.conversation.recent().to_vec() });
        } else if !changed.is_empty() {
            updates.push(Update::Items(changed));
        }
        // A fresh conversation makes the app forget the mode; say it again.
        let mode = self.conversation.mode().map(str::to_owned);
        if mode.is_some() && (fresh || mode != self.mode) {
            updates.push(Update::Mode(mode.clone().expect("some")));
        }
        self.mode = mode;
        self.pending_update(session, &mut updates);
        Ok(updates)
    }

    fn pending_update(&mut self, session: &Session, updates: &mut Vec<Update>) {
        let pending = self.conversation.pending(session.status.as_ref());
        let fresh = matches!(updates.last(), Some(Update::Conversation { .. }));
        if pending != self.pending || (fresh && pending.is_some()) {
            self.pending = pending.clone();
            updates.push(Update::Pending(pending));
        }
    }
}
