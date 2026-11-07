//! Pure state machines for a user-initiated BlueZ operation.
//!
//! This crate performs no D-Bus, device, process, or filesystem operations.
//! A future transport must correlate every asynchronous callback with the
//! supplied owner epoch and operation token before performing an effect.
pub mod discovery;
pub mod pairing;
