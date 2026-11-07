//! Test-only synthetic PipeWire stream reader; caller must isolate PipeWire.
use macshell_capture_stream::Pipeline;
use std::time::{Duration, Instant};
fn main() {
    let node = std::env::args()
        .nth(1)
        .and_then(|v| v.parse().ok())
        .expect("synthetic node id");
    let pipeline = Pipeline::pipewire(node, 160).expect("pipeline");
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        match pipeline.poll() {
            Ok(Some(frame)) => {
                println!("{} {} {}", frame.width, frame.height, frame.png.len());
                break;
            }
            Ok(None) => (),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(2);
            }
        }
        if Instant::now() >= deadline {
            eprintln!("synthetic frame timed out");
            std::process::exit(3);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}
