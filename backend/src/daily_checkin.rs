//! One randomly scheduled NIO CN check-in per Beijing calendar day.
//! The database records an attempt before the upstream POST. A failure that
//! provably happened before the request was sent releases the day's slot and is
//! retried a bounded number of times; ambiguous failures are never retried.

use std::time::Duration;

use chrono::{DateTime, Datelike, FixedOffset, NaiveDate, TimeZone, Utc};
use rand::Rng;
use thiserror::Error;
use tracing::{info, warn};

use crate::{
    rewards::{CheckInOutcome, NioRewardsClient, RewardsError},
    store::{Store, StoreError},
};

/// Maximum number of upstream send attempts per Beijing day.
const MAX_SEND_ATTEMPTS: i32 = 3;
/// Base delay before retrying a request that was never sent; doubles per attempt.
const RETRY_BASE_DELAY_SECONDS: i64 = 5 * 60;

#[derive(Debug, Error)]
pub enum DailyCheckInError {
    #[error("daily check-in already attempted for this Beijing date")]
    AlreadyAttempted,
    #[error("daily check-in date elapsed")]
    DateElapsed,
    #[error("daily check-in request was not sent; a retry is scheduled")]
    RetryScheduled(#[source] RewardsError),
    #[error("daily check-in result could not be persisted")]
    PersistResult(#[source] StoreError),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Rewards(#[from] RewardsError),
}

fn china_zone() -> FixedOffset {
    FixedOffset::east_opt(8 * 3600).expect("valid China time offset")
}

pub fn china_day(now: DateTime<Utc>) -> NaiveDate {
    now.with_timezone(&china_zone()).date_naive()
}

fn next_china_midnight(now: DateTime<Utc>) -> DateTime<Utc> {
    let china = now.with_timezone(&china_zone());
    let tomorrow = china.date_naive().succ_opt().expect("valid next date");
    china_zone()
        .with_ymd_and_hms(tomorrow.year(), tomorrow.month(), tomorrow.day(), 0, 0, 0)
        .single()
        .expect("valid midnight")
        .with_timezone(&Utc)
}

fn random_time_today(now: DateTime<Utc>) -> DateTime<Utc> {
    let seconds_left = (next_china_midnight(now) - now).num_seconds();
    if seconds_left <= 1 {
        return now;
    }
    now + chrono::Duration::seconds(rand::thread_rng().gen_range(1..seconds_left))
}

/// A connection could not be established, so no HTTP request reached upstream.
fn request_was_not_sent(error: &RewardsError) -> bool {
    match error {
        RewardsError::Request(error) => error.is_connect(),
        _ => false,
    }
}

/// Exponential backoff bounded by the send-attempt budget and the Beijing day.
fn retry_time(attempts: i32, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    if attempts <= 0 || attempts >= MAX_SEND_ATTEMPTS {
        return None;
    }
    let factor = 1_i64 << (attempts - 1) as u32;
    let delay = chrono::Duration::seconds(RETRY_BASE_DELAY_SECONDS * factor);
    let candidate = now + delay;
    (candidate < next_china_midnight(now)).then_some(candidate)
}

async fn sleep_until(target: DateTime<Utc>) {
    let wait = (target - Utc::now()).to_std().unwrap_or(Duration::ZERO);
    tokio::time::sleep(wait).await;
}

/// Shared by the automatic job and the existing manual API/MCP tool.
pub async fn perform_once(
    store: &Store,
    rewards: &NioRewardsClient,
    day: NaiveDate,
) -> Result<CheckInOutcome, DailyCheckInError> {
    let now = Utc::now();
    if china_day(now) != day {
        return Err(DailyCheckInError::DateElapsed);
    }
    // Manual calls create today's row too, so they suppress the scheduled job.
    store.daily_checkin_schedule(day, now).await?;
    let Some(attempts) = store.claim_daily_checkin(day).await? else {
        return Err(DailyCheckInError::AlreadyAttempted);
    };
    match rewards.check_in().await {
        Ok(outcome) => {
            store
                .finish_daily_checkin(day, outcome.checked_in, None)
                .await
                .map_err(DailyCheckInError::PersistResult)?;
            Ok(outcome)
        }
        Err(error) => {
            if request_was_not_sent(&error)
                && let Some(retry_at) = retry_time(attempts, Utc::now())
            {
                store
                    .release_daily_checkin(day, retry_at, &error.to_string())
                    .await?;
                return Err(DailyCheckInError::RetryScheduled(error));
            }
            // The request may have been processed upstream. Keep the day claimed.
            if let Err(store_error) = store
                .finish_daily_checkin(day, false, Some(&error.to_string()))
                .await
            {
                warn!(%day, %store_error, %error, "failed to record daily check-in failure");
            }
            Err(DailyCheckInError::Rewards(error))
        }
    }
}

pub async fn run_forever(store: Store, rewards: NioRewardsClient) {
    loop {
        let now = Utc::now();
        let day = china_day(now);
        let candidate = random_time_today(now);
        let schedule = match store.daily_checkin_schedule(day, candidate).await {
            Ok(schedule) => schedule,
            Err(error) => {
                warn!(%error, "failed to read daily check-in schedule");
                tokio::time::sleep(Duration::from_secs(60)).await;
                continue;
            }
        };
        if schedule.attempted_at.is_some() {
            sleep_until(next_china_midnight(now) + chrono::Duration::seconds(1)).await;
            continue;
        }
        info!(
            %day,
            scheduled_at = %schedule.scheduled_at,
            attempts = schedule.attempts,
            result = %schedule.result,
            "daily check-in scheduled"
        );
        sleep_until(schedule.scheduled_at).await;
        if china_day(Utc::now()) != day {
            continue;
        }
        match perform_once(&store, &rewards, day).await {
            Ok(outcome) => info!(%day, checked_in = outcome.checked_in, credit = outcome.credit,
                continuous_days = outcome.continuous_days, "daily check-in finished"),
            Err(DailyCheckInError::AlreadyAttempted) => {
                info!(%day, "daily check-in already attempted by another caller")
            }
            Err(DailyCheckInError::RetryScheduled(error)) => {
                info!(%day, %error, "daily check-in not sent; retry scheduled")
            }
            Err(error) => warn!(%day, %error, "daily check-in failed without automatic retry"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn beijing_day_and_random_time_stay_within_day() {
        let before_midnight = DateTime::parse_from_rfc3339("2026-10-30T15:59:55Z")
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(china_day(before_midnight).to_string(), "2026-10-30");
        for _ in 0..100 {
            let selected = random_time_today(before_midnight);
            assert!(selected > before_midnight);
            assert!(selected < next_china_midnight(before_midnight));
            assert_eq!(china_day(selected), china_day(before_midnight));
        }
        assert_eq!(
            china_day(next_china_midnight(before_midnight)).to_string(),
            "2026-10-31"
        );
    }

    #[test]
    fn retry_delay_is_bounded_by_attempts_and_midnight() {
        let morning = DateTime::parse_from_rfc3339("2026-10-30T02:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(
            retry_time(1, morning),
            Some(morning + chrono::Duration::minutes(5))
        );
        assert_eq!(
            retry_time(2, morning),
            Some(morning + chrono::Duration::minutes(10))
        );
        assert_eq!(retry_time(3, morning), None);
        assert_eq!(retry_time(0, morning), None);

        // 23:58 Beijing: a five-minute retry would cross into the next day.
        let late = DateTime::parse_from_rfc3339("2026-10-30T15:58:00Z")
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(retry_time(1, late), None);
    }

    #[tokio::test]
    async fn schedule_survives_reselection_and_only_one_claim_wins() {
        let Ok(store) = Store::in_memory().await else {
            return; // NIO_TEST_POSTGRES_URL enables PostgreSQL integration tests.
        };
        let now = Utc::now();
        let day = china_day(now);
        let first = now + chrono::Duration::minutes(30);
        let second = now + chrono::Duration::hours(2);
        let original = store.daily_checkin_schedule(day, first).await.unwrap();
        let after_restart = store.daily_checkin_schedule(day, second).await.unwrap();
        assert_eq!(original.scheduled_at, first);
        assert_eq!(after_restart.scheduled_at, first);

        let (a, b) = tokio::join!(
            store.claim_daily_checkin(day),
            store.claim_daily_checkin(day)
        );
        let (a, b) = (a.unwrap(), b.unwrap());
        assert!(a.is_some() ^ b.is_some());
        assert_eq!(a.or(b), Some(1));

        // A request that was never sent releases the slot and keeps the attempt count.
        store
            .release_daily_checkin(day, second, "connection refused")
            .await
            .unwrap();
        let released = store.daily_checkin_schedule(day, second).await.unwrap();
        assert!(released.attempted_at.is_none());
        assert_eq!(released.result, "not_sent");
        assert_eq!(released.attempts, 1);
        assert_eq!(store.claim_daily_checkin(day).await.unwrap(), Some(2));

        store
            .finish_daily_checkin(day, false, Some("upstream failed"))
            .await
            .unwrap();
        let persisted = store.daily_checkin_schedule(day, second).await.unwrap();
        assert!(persisted.attempted_at.is_some());
        assert_eq!(persisted.result, "failed");
        assert_eq!(persisted.attempts, 2);
        assert!(store.claim_daily_checkin(day).await.unwrap().is_none());
    }
}
