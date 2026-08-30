//! Bounded, pull-based lazy execution. Native workers only communicate through
//! a bounded Rust channel; they never enter Dart or invoke foreign callbacks.

use crate::error::{EngineError, Result};
use parking_lot::Mutex;
use polars::prelude::*;
use serde_json::{json, Value};
use std::num::NonZeroUsize;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc::{sync_channel, Receiver, SyncSender, TryRecvError, TrySendError},
    Arc,
};
use std::time::Duration;

enum Message {
    Batch(DataFrame),
    Complete,
    Failed(String),
}

pub struct BatchStream {
    state: Mutex<PollState>,
    cancelled: Arc<AtomicBool>,
}

enum PollStatus {
    Active,
    Complete,
    Cancelled,
}

struct PollState {
    receiver: Receiver<Message>,
    status: PollStatus,
}

impl BatchStream {
    pub fn submit(lazy: LazyFrame, rows: usize, capacity: usize, engine: Engine) -> Arc<Self> {
        let (sender, receiver) = sync_channel(capacity);
        let cancelled = Arc::new(AtomicBool::new(false));
        let worker_cancelled = cancelled.clone();
        std::thread::spawn(move || {
            let batch_sender = sender.clone();
            let callback_cancelled = worker_cancelled.clone();
            let result = lazy
                .sink_batches(
                    PlanCallback::new(move |frame| {
                        Ok(!send_while_active(
                            &batch_sender,
                            Message::Batch(frame),
                            &callback_cancelled,
                        ))
                    }),
                    true,
                    NonZeroUsize::new(rows),
                )
                .and_then(|lazy| lazy.collect_with_engine(engine).map(|_| ()));
            match result {
                Ok(()) => {
                    if !worker_cancelled.load(Ordering::Acquire) {
                        let _ = send_while_active(&sender, Message::Complete, &worker_cancelled);
                    }
                }
                Err(error) => {
                    let _ = send_while_active(
                        &sender,
                        Message::Failed(error.to_string()),
                        &worker_cancelled,
                    );
                }
            }
        });
        Arc::new(Self {
            state: Mutex::new(PollState {
                receiver,
                status: PollStatus::Active,
            }),
            cancelled,
        })
    }

    pub fn poll(&self) -> Result<(Value, Option<DataFrame>)> {
        let mut state = self.state.lock();
        match state.status {
            PollStatus::Cancelled => return Ok((json!({"state":"cancelled"}), None)),
            PollStatus::Complete => return Ok((json!({"state":"complete"}), None)),
            PollStatus::Active => {}
        }
        match state.receiver.try_recv() {
            Ok(Message::Batch(frame)) => Ok((json!({"state":"batch"}), Some(frame))),
            Ok(Message::Complete) => {
                state.status = PollStatus::Complete;
                Ok((json!({"state":"complete"}), None))
            }
            Ok(Message::Failed(message)) => {
                state.status = PollStatus::Complete;
                Err(EngineError::Execution(message))
            }
            Err(TryRecvError::Empty) => Ok((json!({"state":"pending"}), None)),
            Err(TryRecvError::Disconnected) => {
                state.status = PollStatus::Complete;
                Err(EngineError::Internal(
                    "batch stream worker disconnected without a terminal message".into(),
                ))
            }
        }
    }

    pub fn cancel(&self) -> Value {
        let mut state = self.state.lock();
        self.cancelled.store(true, Ordering::Release);
        state.status = PollStatus::Cancelled;
        json!({"state":"cancelled"})
    }
}

/// A blocking `SyncSender::send` cannot observe cancellation while the bounded
/// channel is full. Retrying `try_send` keeps backpressure bounded while also
/// allowing cancel/drop to stop a producer that has no active consumer.
fn send_while_active(
    sender: &SyncSender<Message>,
    mut message: Message,
    cancelled: &AtomicBool,
) -> bool {
    loop {
        if cancelled.load(Ordering::Acquire) {
            return false;
        }
        match sender.try_send(message) {
            Ok(()) => return true,
            Err(TrySendError::Full(returned)) => {
                message = returned;
                std::thread::sleep(Duration::from_millis(1));
            }
            Err(TrySendError::Disconnected(_)) => return false,
        }
    }
}

impl Drop for BatchStream {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
    }
}
