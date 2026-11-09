//! Small typed boundary for existing SQL statements while the store uses Diesel.
//! Query results are decoded through PostgreSQL's row_to_json, which keeps
//! historical nullable columns and timestamp types intact.
use std::marker::PhantomData;

use chrono::{DateTime, NaiveDate, Utc};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::sql_types::{BigInt, Bool, Date, Double, Nullable, Text, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde::{Deserialize, de::DeserializeOwned};
use thiserror::Error;

use crate::pg_store::PgPool;

#[derive(Debug, Error)]
pub enum Error {
    #[error(transparent)]
    Diesel(#[from] diesel::result::Error),
    #[error(transparent)]
    Pool(#[from] diesel_async::pooled_connection::deadpool::PoolError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("missing column {0}")]
    MissingColumn(String),
}

#[derive(Clone, Debug, Deserialize)]
#[serde(transparent)]
pub struct Row(serde_json::Map<String, serde_json::Value>);

impl Row {
    pub fn try_get<T: DeserializeOwned, I: AsRef<str>>(&self, name: I) -> Result<T, Error> {
        let name = name.as_ref();
        let value = self
            .0
            .get(name)
            .ok_or_else(|| Error::MissingColumn(name.to_owned()))?;
        Ok(serde_json::from_value(value.clone())?)
    }
}

#[derive(Clone)]
pub enum Param {
    Text(Option<String>),
    BigInt(Option<i64>),
    Double(Option<f64>),
    Bool(Option<bool>),
    Timestamp(Option<DateTime<Utc>>),
    Date(Option<NaiveDate>),
}

pub trait IntoParam {
    fn into_param(self) -> Param;
}
impl IntoParam for String {
    fn into_param(self) -> Param {
        Param::Text(Some(self))
    }
}
impl IntoParam for &String {
    fn into_param(self) -> Param {
        Param::Text(Some(self.clone()))
    }
}
impl IntoParam for &str {
    fn into_param(self) -> Param {
        Param::Text(Some(self.to_owned()))
    }
}
impl IntoParam for Option<String> {
    fn into_param(self) -> Param {
        Param::Text(self)
    }
}
impl IntoParam for &Option<String> {
    fn into_param(self) -> Param {
        Param::Text(self.clone())
    }
}
impl IntoParam for Option<&str> {
    fn into_param(self) -> Param {
        Param::Text(self.map(str::to_owned))
    }
}
impl IntoParam for i64 {
    fn into_param(self) -> Param {
        Param::BigInt(Some(self))
    }
}
impl IntoParam for Option<i64> {
    fn into_param(self) -> Param {
        Param::BigInt(self)
    }
}
impl IntoParam for f64 {
    fn into_param(self) -> Param {
        Param::Double(Some(self))
    }
}
impl IntoParam for Option<f64> {
    fn into_param(self) -> Param {
        Param::Double(self)
    }
}
impl IntoParam for bool {
    fn into_param(self) -> Param {
        Param::Bool(Some(self))
    }
}
impl IntoParam for DateTime<Utc> {
    fn into_param(self) -> Param {
        Param::Timestamp(Some(self))
    }
}
impl IntoParam for Option<DateTime<Utc>> {
    fn into_param(self) -> Param {
        Param::Timestamp(self)
    }
}
impl IntoParam for NaiveDate {
    fn into_param(self) -> Param {
        Param::Date(Some(self))
    }
}
impl IntoParam for Option<NaiveDate> {
    fn into_param(self) -> Param {
        Param::Date(self)
    }
}

#[derive(QueryableByName)]
struct JsonRow {
    #[diesel(sql_type = Text)]
    payload: String,
}

pub struct Query<T> {
    sql: String,
    params: Vec<Param>,
    scalar: bool,
    marker: PhantomData<T>,
}

pub fn query(sql: &str) -> Query<Row> {
    Query::new(sql)
}
pub fn query_as<T: DeserializeOwned>(sql: &str) -> Query<T> {
    Query::new(sql)
}
pub fn query_scalar<T: DeserializeOwned>(sql: &str) -> Query<T> {
    let mut query = Query::new(sql);
    query.scalar = true;
    query
}

impl<T> Query<T> {
    fn new(sql: &str) -> Self {
        Self {
            sql: pg_placeholders(sql),
            params: Vec::new(),
            scalar: false,
            marker: PhantomData,
        }
    }

    pub fn bind<P: IntoParam>(mut self, value: P) -> Self {
        self.params.push(value.into_param());
        self
    }

    fn diesel_query(
        &self,
        sql: String,
    ) -> diesel::query_builder::BoxedSqlQuery<'static, Pg, diesel::query_builder::SqlQuery> {
        let mut query = diesel::sql_query(sql).into_boxed::<Pg>();
        for param in &self.params {
            query = match param {
                Param::Text(v) => query.bind::<Nullable<Text>, _>(v.clone()),
                Param::BigInt(v) => query.bind::<Nullable<BigInt>, _>(*v),
                Param::Double(v) => query.bind::<Nullable<Double>, _>(*v),
                Param::Bool(v) => query.bind::<Nullable<Bool>, _>(*v),
                Param::Timestamp(v) => query.bind::<Nullable<Timestamptz>, _>(*v),
                Param::Date(v) => query.bind::<Nullable<Date>, _>(*v),
            };
        }
        query
    }

    pub async fn execute(&self, pool: &PgPool) -> Result<Execution, Error> {
        let mut conn = pool.get().await?;
        self.execute_conn(&mut conn).await
    }

    pub async fn execute_conn(&self, conn: &mut AsyncPgConnection) -> Result<Execution, Error> {
        let affected = self.diesel_query(self.sql.clone()).execute(conn).await?;
        Ok(Execution(affected as u64))
    }
}

impl<T: DeserializeOwned> Query<T> {
    pub async fn fetch_all(&self, pool: &PgPool) -> Result<Vec<T>, Error> {
        let mut conn = pool.get().await?;
        let wrapped = format!(
            "SELECT row_to_json(q)::text AS payload FROM ({}) q",
            self.sql
        );
        let rows: Vec<JsonRow> = self.diesel_query(wrapped).load(&mut conn).await?;
        rows.into_iter()
            .map(|row| {
                let mut value: serde_json::Value = serde_json::from_str(&row.payload)?;
                if self.scalar {
                    value = value
                        .as_object_mut()
                        .and_then(|object| object.values().next().cloned())
                        .ok_or_else(|| Error::MissingColumn("scalar result".to_owned()))?;
                }
                Ok(serde_json::from_value(value)?)
            })
            .collect()
    }

    pub async fn fetch_optional(&self, pool: &PgPool) -> Result<Option<T>, Error> {
        Ok(self.fetch_all(pool).await?.into_iter().next())
    }

    pub async fn fetch_one(&self, pool: &PgPool) -> Result<T, Error> {
        self.fetch_optional(pool)
            .await?
            .ok_or(Error::Diesel(diesel::result::Error::NotFound))
    }
}

#[derive(Clone, Copy)]
pub struct Execution(u64);
impl Execution {
    pub fn rows_affected(self) -> u64 {
        self.0
    }
}

fn pg_placeholders(sql: &str) -> String {
    let mut out = String::with_capacity(sql.len() + 16);
    let mut in_single = false;
    let mut next = 1;
    for ch in sql.chars() {
        match ch {
            '\'' => {
                in_single = !in_single;
                out.push(ch);
            }
            '?' if !in_single => {
                out.push('$');
                out.push_str(&next.to_string());
                next += 1;
            }
            _ => out.push(ch),
        }
    }
    out
}
