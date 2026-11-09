//! One randomly scheduled NIO CN check-in per Beijing calendar day.
//! The database records an attempt before the upstream POST. Ambiguous failures
//! are deliberately left for manual inspection rather than retried.

use std::time::Duration;

use chrono::{DateTime, Datelike, FixedOffset, NaiveDate, TimeZone, Utc};
use rand::Rng;
use thiserror::Error;
use tracing::{info, warn};

use crate::{
    rewards::{CheckInOutcome, NioRewardsClient, RewardsError},
    store::{Store, StoreError},
};

#[derive(Debug, Error)]
pub enum DailyCheckInError {
    #[error("daily check-in already attempted for this Beijing date")]
    AlreadyAttempted,
    #[error("daily check-in date elapsed")]
    DateElapsed,
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
    if !store.claim_daily_checkin(day).await? {
        return Err(DailyCheckInError::AlreadyAttempted);
    }
    let result = rewards.check_in().await;
    if let Err(error) = store
        .finish_daily_checkin(day, result.as_ref().is_ok_and(|outcome| outcome.checked_in))
        .await
    {
        warn!(%day, %error, "failed to record daily check-in result; attempt remains claimed");
    }
    Ok(result?)
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
        info!(%day, scheduled_at = %schedule.scheduled_at, "daily check-in scheduled");
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
        assert_ne!(a.unwrap(), b.unwrap());
        store.finish_daily_checkin(day, false).await.unwrap();
        let persisted = store.daily_checkin_schedule(day, second).await.unwrap();
        assert!(persisted.attempted_at.is_some());
        assert!(!store.claim_daily_checkin(day).await.unwrap());
    }
}
