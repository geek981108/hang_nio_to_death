use std::{collections::VecDeque, sync::Arc, time::Duration};

use actix_web::{Error, HttpResponse, web::Bytes};
use chrono::{DateTime, Utc};
use diesel::{
    QueryableByName,
    sql_types::{BigInt, Text, Timestamptz},
};
use diesel_async::RunQueryDsl;
use futures_util::stream::{self, Stream};
use serde::Deserialize;
use tokio::sync::{Mutex, broadcast};

use crate::{
    diesel_query as db,
    store::{Store, StoreError},
};

const REPLAY_LIMIT: i64 = 256;
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);

#[derive(Clone, Debug)]
struct Event {
    id: i64,
    event_type: String,
    reason: String,
    occurred_at: DateTime<Utc>,
}

#[derive(Deserialize)]
struct StoredEvent {
    id: i64,
    event_type: String,
    data: String,
    created_at: DateTime<Utc>,
}

#[derive(QueryableByName)]
struct InsertedId {
    #[diesel(sql_type = BigInt)]
    id: i64,
}

impl From<StoredEvent> for Event {
    fn from(row: StoredEvent) -> Self {
        Self {
            id: row.id,
            event_type: row.event_type,
            reason: row.data,
            occurred_at: row.created_at,
        }
    }
}

#[derive(Clone)]
pub struct EventHub {
    inner: Arc<Inner>,
}

struct Inner {
    store: Store,
    sender: broadcast::Sender<Event>,
    gate: Mutex<()>,
}

impl EventHub {
    pub fn new(store: Store) -> Self {
        let (sender, _) = broadcast::channel(256);
        Self {
            inner: Arc::new(Inner {
                store,
                sender,
                gate: Mutex::new(()),
            }),
        }
    }

    pub async fn publish(
        &self,
        event_type: &'static str,
        reason: &'static str,
    ) -> Result<(), StoreError> {
        let _guard = self.inner.gate.lock().await;
        let now = Utc::now();
        let mut connection = self.inner.store.pool.get().await.map_err(db::Error::from)?;
        let id = diesel::sql_query("INSERT INTO sse_events (event_type, data, created_at) VALUES ($1, $2, $3) RETURNING id")
            .bind::<Text, _>(event_type)
            .bind::<Text, _>(reason)
            .bind::<Timestamptz, _>(now)
            .get_result::<InsertedId>(&mut connection)
            .await
            .map_err(db::Error::from)?
            .id;
        if let Err(error) = diesel::sql_query(
            "DELETE FROM sse_events WHERE id <= (SELECT COALESCE(MAX(id), 0) - $1 FROM sse_events)",
        )
        .bind::<BigInt, _>(REPLAY_LIMIT)
        .execute(&mut connection)
        .await
        {
            tracing::warn!(%error, "failed to trim SSE replay window");
        }
        drop(connection);
        let _ = self.inner.sender.send(Event {
            id,
            event_type: event_type.into(),
            reason: reason.into(),
            occurred_at: now,
        });
        Ok(())
    }

    async fn latest_id(&self) -> Result<i64, StoreError> {
        Ok(
            db::query_scalar::<i64>("SELECT COALESCE(MAX(id), 0) FROM sse_events")
                .fetch_one(&self.inner.store.pool)
                .await?,
        )
    }

    async fn subscribe(&self, last_event_id: Option<&str>) -> Result<StreamState, StoreError> {
        let _guard = self.inner.gate.lock().await;
        let receiver = self.inner.sender.subscribe();
        let latest = self.latest_id().await?;
        let oldest = db::query_scalar::<i64>("SELECT COALESCE(MIN(id), 0) FROM sse_events")
            .fetch_one(&self.inner.store.pool)
            .await?;
        let mut pending = VecDeque::new();
        let mut last_sent = latest;
        match last_event_id {
            None => pending.push_back((latest, control_frame("ready", latest, "initial_connect"))),
            Some(raw) => match raw.parse::<i64>() {
                Ok(cursor) if cursor >= oldest.saturating_sub(1) && cursor <= latest => {
                    let rows = db::query_as::<StoredEvent>(
                        "SELECT id, event_type, data, created_at FROM sse_events WHERE id > ? ORDER BY id ASC LIMIT ?"
                    ).bind(cursor).bind(REPLAY_LIMIT).fetch_all(&self.inner.store.pool).await?;
                    last_sent = cursor;
                    for row in rows {
                        let event: Event = row.into();
                        pending.push_back((event.id, event_frame(&event)));
                    }
                }
                _ => pending.push_back((
                    latest,
                    control_frame("resync", latest, "cursor_unavailable"),
                )),
            },
        }
        // The receiver subscribes before the replay query. Frames already replayed
        // from PostgreSQL are skipped when they appear again in the broadcast queue.
        Ok(StreamState {
            hub: self.clone(),
            receiver,
            pending,
            last_sent,
            heartbeat: tokio::time::interval_at(
                tokio::time::Instant::now() + HEARTBEAT_INTERVAL,
                HEARTBEAT_INTERVAL,
            ),
        })
    }

    pub async fn response(&self, last_event_id: Option<&str>) -> Result<HttpResponse, StoreError> {
        let state = self.subscribe(last_event_id).await?;
        Ok(HttpResponse::Ok()
            .insert_header(("Content-Type", "text/event-stream"))
            .insert_header(("Cache-Control", "no-cache"))
            .insert_header(("Connection", "keep-alive"))
            .insert_header(("X-Accel-Buffering", "no"))
            .streaming(event_stream(state)))
    }
}

struct StreamState {
    hub: EventHub,
    receiver: broadcast::Receiver<Event>,
    pending: VecDeque<(i64, String)>,
    last_sent: i64,
    heartbeat: tokio::time::Interval,
}

fn event_stream(state: StreamState) -> impl Stream<Item = Result<Bytes, Error>> {
    stream::unfold(state, |mut state| async move {
        loop {
            if let Some((id, frame)) = state.pending.pop_front() {
                state.last_sent = id;
                return Some((Ok(Bytes::from(frame)), state));
            }
            tokio::select! {
                result = state.receiver.recv() => match result {
                    Ok(event) if event.id > state.last_sent => {
                        if event.id != state.last_sent + 1 {
                            state.last_sent = state.hub.latest_id().await.unwrap_or(event.id);
                            return Some((Ok(Bytes::from(control_frame("resync", state.last_sent, "event_gap"))), state));
                        }
                        state.last_sent = event.id;
                        return Some((Ok(Bytes::from(event_frame(&event))), state));
                    }
                    Ok(_) => continue,
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        state.last_sent = state.hub.latest_id().await.unwrap_or(state.last_sent);
                        return Some((Ok(Bytes::from(control_frame("resync", state.last_sent, "consumer_lag"))), state));
                    }
                    Err(broadcast::error::RecvError::Closed) => return None,
                },
                _ = state.heartbeat.tick() => return Some((Ok(Bytes::from_static(b": heartbeat\n\n")), state)),
            }
        }
    })
}

fn event_frame(event: &Event) -> String {
    let data = serde_json::json!({
        "schema_version": 1, "occurred_at": event.occurred_at,
        "revision": event.id, "reason": event.reason,
    });
    format!(
        "id: {}\nevent: {}\nretry: 3000\ndata: {}\n\n",
        event.id, event.event_type, data
    )
}

fn control_frame(kind: &str, revision: i64, reason: &str) -> String {
    let data = serde_json::json!({
        "schema_version": 1, "occurred_at": Utc::now(),
        "revision": revision, "reason": reason,
    });
    format!("id: {revision}\nevent: {kind}\nretry: 3000\ndata: {data}\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::StreamExt;

    #[test]
    fn sse_frame_contains_id_event_retry_and_small_json() {
        let frame = event_frame(&Event {
            id: 7,
            event_type: "vehicle_changed".into(),
            reason: "vehicle_status_changed".into(),
            occurred_at: Utc::now(),
        });
        assert!(frame.starts_with("id: 7\nevent: vehicle_changed\nretry: 3000\ndata: "));
        assert!(frame.contains("\"revision\":7"));
        assert!(!frame.contains("door_status"));
    }

    #[tokio::test]
    async fn replays_missing_events_and_resyncs_expired_or_unknown_cursor() {
        let store = match Store::in_memory().await {
            Ok(store) => store,
            Err(_) if std::env::var_os("NIO_TEST_POSTGRES_URL").is_none() => return,
            Err(error) => panic!("PostgreSQL test setup failed: {error}"),
        };
        let hub = EventHub::new(store.clone());
        let mut first = hub.subscribe(None).await.unwrap();
        assert!(
            first
                .pending
                .pop_front()
                .unwrap()
                .1
                .contains("event: ready")
        );
        hub.publish("vehicle_changed", "vehicle_status_changed")
            .await
            .unwrap();
        hub.publish("active_orders_changed", "active_orders_changed")
            .await
            .unwrap();
        let mut replay = hub.subscribe(Some("1")).await.unwrap();
        assert_eq!(replay.pending.len(), 1);
        assert!(
            replay
                .pending
                .pop_front()
                .unwrap()
                .1
                .contains("event: active_orders_changed")
        );
        let mut unknown = hub.subscribe(Some("bad-id")).await.unwrap();
        assert!(
            unknown
                .pending
                .pop_front()
                .unwrap()
                .1
                .contains("event: resync")
        );
        let mut stream = Box::pin(event_stream(hub.subscribe(Some("2")).await.unwrap()));
        hub.publish("vehicle_changed", "vehicle_status_changed")
            .await
            .unwrap();
        let frame = stream.next().await.unwrap().unwrap();
        assert!(
            std::str::from_utf8(&frame)
                .unwrap()
                .contains("id: 3\nevent: vehicle_changed")
        );

        let other = EventHub::new(Store::in_memory().await.unwrap());
        assert_eq!(other.latest_id().await.unwrap(), 0);
        assert_eq!(hub.latest_id().await.unwrap(), 3);
    }

    #[tokio::test]
    async fn expired_cursor_and_slow_subscriber_resync_and_disconnect_cleans_up() {
        let store = match Store::in_memory().await {
            Ok(store) => store,
            Err(_) if std::env::var_os("NIO_TEST_POSTGRES_URL").is_none() => return,
            Err(error) => panic!("PostgreSQL test setup failed: {error}"),
        };
        let hub = EventHub::new(store);
        let subscriber = hub.subscribe(None).await.unwrap();
        assert_eq!(hub.inner.sender.receiver_count(), 1);
        for _ in 0..258 {
            hub.publish("vehicle_changed", "vehicle_status_changed")
                .await
                .unwrap();
        }
        let mut expired = hub.subscribe(Some("1")).await.unwrap();
        assert!(
            expired
                .pending
                .pop_front()
                .unwrap()
                .1
                .contains("event: resync")
        );
        let mut stream = Box::pin(event_stream(subscriber));
        assert!(
            std::str::from_utf8(&stream.next().await.unwrap().unwrap())
                .unwrap()
                .contains("event: ready")
        );
        assert!(
            std::str::from_utf8(&stream.next().await.unwrap().unwrap())
                .unwrap()
                .contains("reason\":\"consumer_lag")
        );
        drop(stream);
        drop(expired);
        assert_eq!(hub.inner.sender.receiver_count(), 0);
    }

    #[tokio::test]
    async fn heartbeat_is_a_comment_and_restart_can_replay_persisted_events() {
        let store = match Store::in_memory().await {
            Ok(store) => store,
            Err(_) if std::env::var_os("NIO_TEST_POSTGRES_URL").is_none() => return,
            Err(error) => panic!("PostgreSQL test setup failed: {error}"),
        };
        let hub = EventHub::new(store.clone());
        hub.publish("vehicle_changed", "vehicle_status_changed")
            .await
            .unwrap();
        let mut state = hub.subscribe(None).await.unwrap();
        state.heartbeat = tokio::time::interval_at(
            tokio::time::Instant::now() + Duration::from_millis(1),
            Duration::from_millis(1),
        );
        let mut stream = Box::pin(event_stream(state));
        assert!(
            std::str::from_utf8(&stream.next().await.unwrap().unwrap())
                .unwrap()
                .contains("event: ready")
        );
        assert_eq!(
            &stream.next().await.unwrap().unwrap()[..],
            b": heartbeat\n\n"
        );
        drop(stream);
        drop(hub);
        let restarted = EventHub::new(store);
        restarted
            .publish("active_orders_changed", "active_orders_changed")
            .await
            .unwrap();
        let mut replay = restarted.subscribe(Some("1")).await.unwrap();
        assert!(
            replay
                .pending
                .pop_front()
                .unwrap()
                .1
                .contains("event: active_orders_changed")
        );
    }
}
