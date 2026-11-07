//! Test-only newline-delimited geometry oracle, no capture is started.
use macshell_recording_core::{geometry, Output};
use std::io::{self, BufRead};

fn main() {
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let values: Vec<_> = line.splitn(5, ' ').collect();
        if values.len() != 5 {
            println!("ERROR");
            continue;
        }
        let output = Output {
            x: values[0].parse().unwrap(),
            y: values[1].parse().unwrap(),
            width: values[2].parse().unwrap(),
            height: values[3].parse().unwrap(),
        };
        match geometry(values[4], output) {
            Ok(value) => println!("OK {value}"),
            Err(_) => println!("ERROR"),
        }
    }
}
