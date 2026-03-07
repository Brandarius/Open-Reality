use crossterm::event::{self, Event as CEvent, KeyEvent};
use std::time::Duration;
use tokio::sync::mpsc;

use crate::build::BuildEvent;
use crate::runner::RunEvent;

#[derive(Debug)]
pub enum AppEvent {
    Key(KeyEvent),
    Tick,
    Build(BuildEvent),
    Run(RunEvent),
    Setup(RunEvent),
    Test(RunEvent),
}

pub fn spawn_event_reader(tx: mpsc::UnboundedSender<AppEvent>) {
    std::thread::spawn(move || loop {
        if event::poll(Duration::from_millis(100)).unwrap_or(false) {
            if let Ok(CEvent::Key(key)) = event::read() {
                if tx.send(AppEvent::Key(key)).is_err() {
                    return;
                }
            }
        } else if tx.send(AppEvent::Tick).is_err() {
            return;
        }
    });
}
