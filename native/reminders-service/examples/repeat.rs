use chrono::NaiveDate;
use macshell_reminders_service::{next_occurrence, Repeat, Rule};

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.len() != 8 { std::process::exit(2); }
    let rule = match args[0].as_str() { "daily" => Rule::Daily, "weekly" => Rule::Weekly, "monthly" => Rule::Monthly, _ => std::process::exit(2) };
    let repeat = Repeat { rule, zone: args[1].parse().unwrap(), date: NaiveDate::parse_from_str(&args[2], "%Y-%m-%d").unwrap(), day: args[3].parse().unwrap(), hour: args[4].parse().unwrap(), minute: args[5].parse().unwrap(), due_ms: args[6].parse().unwrap() };
    match next_occurrence(&repeat, args[7].parse().unwrap()) { Some((day, ms)) => println!("{day} {ms}"), None => std::process::exit(1) }
}
