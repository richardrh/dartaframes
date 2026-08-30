use crate::error::{EngineError, Result};
use parking_lot::Mutex;
use polars::prelude::*;
use serde_json::{json, Value};
use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc::{Receiver, TryRecvError},
        Arc,
    },
};

const MAX_ACTIVE_JOBS: usize = 64;
static ACTIVE_JOB_OBSERVERS: AtomicUsize = AtomicUsize::new(0);

struct ObserverPermit;

impl ObserverPermit {
    fn reserve() -> Result<Self> {
        ACTIVE_JOB_OBSERVERS
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < MAX_ACTIVE_JOBS).then_some(active + 1)
            })
            .map_err(|_| {
                EngineError::Unsupported(format!(
                    "at most {MAX_ACTIVE_JOBS} asynchronous jobs may be active"
                ))
            })?;
        Ok(Self)
    }
}

impl Drop for ObserverPermit {
    fn drop(&mut self) {
        ACTIVE_JOB_OBSERVERS.fetch_sub(1, Ordering::AcqRel);
    }
}

struct RunningQuery {
    query: InProcessQuery,
    result: Receiver<Result<DataFrame>>,
}

enum State {
    Running {
        query: RunningQuery,
        cancel_requested: bool,
    },
    Complete(Result<DataFrame>),
    Taken,
}

/// A genuinely native, non-blocking Polars query retaining Polars' cooperative
/// cancellation token. Explicit engines are intentionally rejected because
/// Polars 0.55.2 does not expose equivalent cancellation for them.
pub struct Job {
    state: Mutex<State>,
}

impl Job {
    pub fn submit(lf: LazyFrame, engine: Engine) -> Result<Arc<Self>> {
        if engine != Engine::Auto {
            return Err(EngineError::Unsupported(
                "asynchronous jobs require the auto engine for cooperative cancellation".into(),
            ));
        }
        let permit = ObserverPermit::reserve()?;
        let query = lf.collect_concurrently()?;
        let observer = query.clone();
        let (send, result) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("dartaframes-job-observer".into())
            .spawn(move || {
                let _permit = permit;
                let observed = catch_unwind(AssertUnwindSafe(|| observer.fetch_blocking()))
                    .map_err(|_| {
                        EngineError::Internal("native query worker disconnected or panicked".into())
                    })
                    .and_then(|result| result.map_err(EngineError::from));
                let _ = send.send(observed);
            })
            .map_err(|error| {
                EngineError::Internal(format!("could not start query observer: {error}"))
            })?;
        Ok(Arc::new(Self {
            state: Mutex::new(State::Running {
                query: RunningQuery { query, result },
                cancel_requested: false,
            }),
        }))
    }

    fn refresh(state: &mut State) {
        let update = match state {
            State::Running {
                query,
                cancel_requested,
            } => match query.result.try_recv() {
                Ok(result) => Some(if *cancel_requested {
                    let _ = result;
                    Err(EngineError::Cancelled("job was cancelled".into()))
                } else {
                    result
                }),
                Err(TryRecvError::Empty) => None,
                Err(TryRecvError::Disconnected) => Some(Err(EngineError::Internal(
                    "native query observer disconnected without a result".into(),
                ))),
            },
            _ => None,
        };
        if let Some(result) = update {
            *state = State::Complete(result);
        }
    }

    pub fn poll(&self) -> Value {
        let mut state = self.state.lock();
        Self::refresh(&mut state);
        match &*state {
            State::Running {
                cancel_requested, ..
            } => {
                json!({"state":if *cancel_requested {"cancelling"} else {"running"}})
            }
            State::Complete(Ok(_)) => json!({"state":"complete"}),
            State::Complete(Err(e)) => {
                let state = if matches!(e, EngineError::Cancelled(_)) {
                    "cancelled"
                } else {
                    "failed"
                };
                json!({"state":state,"error":e.envelope()["error"].clone()})
            }
            State::Taken => json!({"state":"taken"}),
        }
    }

    pub fn cancel(&self) -> Value {
        let mut state = self.state.lock();
        Self::refresh(&mut state);
        let requested = if let State::Running {
            query,
            cancel_requested,
            ..
        } = &mut *state
        {
            query.query.cancel();
            *cancel_requested = true;
            true
        } else {
            false
        };
        json!({"cancelRequested":requested})
    }

    pub fn take(&self) -> Result<Option<DataFrame>> {
        let mut state = self.state.lock();
        Self::refresh(&mut state);
        match std::mem::replace(&mut *state, State::Taken) {
            running @ State::Running { .. } => {
                *state = running;
                Ok(None)
            }
            State::Complete(result) => result.map(Some),
            State::Taken => {
                *state = State::Taken;
                Err(EngineError::Invalid("job result already taken".into()))
            }
        }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        if let State::Running { query, .. } = self.state.get_mut() {
            query.query.cancel();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancellation_is_terminal_and_take_is_atomic() {
        let frame = df!("a" => [1_i32]).unwrap();
        let lazy = frame.lazy().map(
            |frame| {
                std::thread::sleep(std::time::Duration::from_millis(25));
                Ok(frame)
            },
            AllowedOptimizations::default(),
            None,
            Some("cancellation-test"),
        );
        let job = Job::submit(lazy, Engine::Auto).unwrap();
        assert_eq!(job.cancel()["cancelRequested"], true);
        loop {
            let status = job.poll();
            match status["state"].as_str().unwrap() {
                "cancelling" => std::thread::sleep(std::time::Duration::from_millis(1)),
                "cancelled" => {
                    assert_eq!(status["error"]["category"], "cancelled");
                    break;
                }
                state => panic!("unexpected terminal state {state}: {status}"),
            }
        }
        assert!(matches!(job.take(), Err(EngineError::Cancelled(_))));
        assert!(matches!(job.take(), Err(EngineError::Invalid(_))));
    }

    #[test]
    fn abandoning_a_running_job_drops_it_immediately() {
        let lazy = df!("a" => [1_i32]).unwrap().lazy().map(
            |frame| {
                std::thread::sleep(std::time::Duration::from_millis(20));
                Ok(frame)
            },
            AllowedOptimizations::default(),
            None,
            Some("abandonment-test"),
        );
        let job = Job::submit(lazy, Engine::Auto).unwrap();
        let weak = Arc::downgrade(&job);
        drop(job);
        assert!(weak.upgrade().is_none());
    }
}
