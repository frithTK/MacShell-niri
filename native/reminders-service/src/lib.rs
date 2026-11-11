use chrono::{Datelike, Duration, LocalResult, NaiveDate, TimeZone, Timelike, Utc};
use chrono_tz::Tz;

#[derive(Debug, Clone, Copy)]
pub enum Rule { Daily, Weekly, Monthly }

#[derive(Debug, Clone)]
pub struct Repeat {
    pub rule: Rule,
    pub zone: Tz,
    pub date: NaiveDate,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub due_ms: i64,
}

pub fn occurrence_instant(zone: Tz, date: NaiveDate, hour: u32, minute: u32) -> Option<i64> {
    resolve(zone, date, hour, minute)
}

fn resolve(zone: Tz, date: NaiveDate, hour: u32, minute: u32) -> Option<i64> {
    let local = date.and_hms_opt(hour, minute, 0)?;
    let choose = |time| match zone.from_local_datetime(&time) {
        LocalResult::Single(v) => Some(v.timestamp_millis()),
        LocalResult::Ambiguous(a, b) => Some(a.timestamp_millis().min(b.timestamp_millis())),
        LocalResult::None => None,
    };
    if let Some(value) = choose(local) { return Some(value); }
    for offset in 1..=2880 {
        let candidate = local.checked_add_signed(Duration::minutes(offset))?;
        if choose(candidate).is_some() {
            let previous = candidate.checked_sub_signed(Duration::minutes(1))?;
            for seconds in 1..=60 { if let Some(value) = choose(previous.checked_add_signed(Duration::seconds(seconds))?) { return Some(value); } }
        }
    }
    None
}

fn month_after(date: NaiveDate, count: i32, day: u32) -> Option<NaiveDate> {
    let index = date.year().checked_mul(12)?.checked_add(date.month0() as i32)?.checked_add(count)?;
    let year = index.div_euclid(12); let month = index.rem_euclid(12) as u32 + 1;
    let next = if month == 12 { NaiveDate::from_ymd_opt(year.checked_add(1)?, 1, 1)? } else { NaiveDate::from_ymd_opt(year, month + 1, 1)? };
    let last = next.pred_opt()?.day();
    NaiveDate::from_ymd_opt(year, month, day.min(last))
}

pub fn next_occurrence(repeat: &Repeat, now_ms: i64) -> Option<(NaiveDate, i64)> {
    if repeat.day == 0 || repeat.day > 31 || repeat.hour > 23 || repeat.minute > 59 { return None; }
    let threshold = repeat.due_ms.max(now_ms);
    let after = Utc.timestamp_millis_opt(threshold).single()?.with_timezone(&repeat.zone).date_naive();
    let mut candidate = match repeat.rule {
        Rule::Daily | Rule::Weekly => {
            let period = if matches!(repeat.rule, Rule::Daily) {1} else {7};
            let steps = ((after - repeat.date).num_days().div_euclid(period)).max(1);
            repeat.date.checked_add_signed(Duration::days(steps.checked_mul(period)?))?
        },
        Rule::Monthly => {
            let steps = ((after.year() - repeat.date.year()) * 12 + after.month() as i32 - repeat.date.month() as i32).max(1);
            month_after(repeat.date, steps, repeat.day)?
        }
    };
    loop {
        let instant = resolve(repeat.zone, candidate, repeat.hour, repeat.minute)?;
        if instant > threshold { return Some((candidate, instant)); }
        candidate = match repeat.rule {
            Rule::Daily => candidate.succ_opt()?,
            Rule::Weekly => candidate.checked_add_signed(Duration::days(7))?,
            Rule::Monthly => month_after(candidate, 1, repeat.day)?,
        };
    }
}

pub fn repeat_fields(due_ms: i64, zone: Tz) -> Option<(NaiveDate, u32, u32, u32)> {
    let local = Utc.timestamp_millis_opt(due_ms).single()?.with_timezone(&zone);
    Some((local.date_naive(), local.day(), local.hour(), local.minute()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn repeat(rule: Rule, zone: &str, date: (i32,u32,u32), day: u32, hour: u32, minute: u32, due_ms: i64) -> Repeat {
        Repeat { rule, zone: zone.parse().unwrap(), date: NaiveDate::from_ymd_opt(date.0,date.1,date.2).unwrap(), day, hour, minute, due_ms }
    }

    #[test]
    fn monthly_preserves_original_day_across_short_month() {
        let due = Utc.with_ymd_and_hms(2026,1,31,9,0,0).unwrap().timestamp_millis();
        let mut r = repeat(Rule::Monthly,"UTC",(2026,1,31),31,9,0,due);
        let (day, ms) = next_occurrence(&r,due).unwrap();
        assert_eq!(day.to_string(),"2026-02-28");
        r.date = day; r.due_ms = ms;
        assert_eq!(next_occurrence(&r,ms).unwrap().0.to_string(),"2026-03-31");
    }

    #[test]
    fn gap_moves_to_first_valid_time_and_fold_chooses_first() {
        let gap = repeat(Rule::Daily,"America/New_York",(2026,3,7),7,2,30,Utc.with_ymd_and_hms(2026,3,7,7,30,0).unwrap().timestamp_millis());
        let (_, result) = next_occurrence(&gap,gap.due_ms).unwrap();
        assert_eq!(result,Utc.with_ymd_and_hms(2026,3,8,7,0,0).unwrap().timestamp_millis());
        let fold = repeat(Rule::Daily,"America/New_York",(2026,10,31),31,1,30,Utc.with_ymd_and_hms(2026,10,31,5,30,0).unwrap().timestamp_millis());
        assert_eq!(next_occurrence(&fold,fold.due_ms).unwrap().1,Utc.with_ymd_and_hms(2026,11,1,5,30,0).unwrap().timestamp_millis());
    }

    #[test]
    fn skipped_date_and_long_overdue_weekly_schedule() {
        let r = repeat(Rule::Daily,"Pacific/Apia",(2011,12,29),29,12,0,Utc.with_ymd_and_hms(2011,12,29,22,0,0).unwrap().timestamp_millis());
        assert_eq!(next_occurrence(&r,r.due_ms).unwrap().1,Utc.with_ymd_and_hms(2011,12,30,10,0,0).unwrap().timestamp_millis());
        let r = repeat(Rule::Weekly,"UTC",(2026,1,1),1,9,0,Utc.with_ymd_and_hms(2026,1,1,9,0,0).unwrap().timestamp_millis());
        let now = Utc.with_ymd_and_hms(2026,2,1,12,0,0).unwrap().timestamp_millis();
        assert_eq!(next_occurrence(&r,now).unwrap().0.to_string(),"2026-02-05");
    }
}
