# NetworkManager snapshot

This is a read-only building block for the planned Rust Wi-Fi service. It is not
currently connected to QML or installed. `read()` uses a dedicated Gio
connection to fetch NetworkManager devices, access points and non-secret
connection settings, then produces the existing Wi-Fi state shape.
`worker::Worker` runs a supplied bounded reader on a background thread and
fences output by owner epoch and latest accepted request. The caller must retry
when the one-item request queue is full, periodically drain `poll()`, report
every owner transition, and close the worker's dedicated connection. Dropping
the worker does not wait for a stuck reader; stale output is discarded.

`action_worker::ActionWorker` is separate from the snapshot worker: it permits
only one potentially mutating operation at a time. Cancel records intent but
does not discard a later result, because a returned connection path may be
needed to reconcile cancellation. Owner transitions fence old results; a stale
completion says whether the operation may have run. A stopped thread while an
operation is pending is uncertain. The supplied callback must close its own
dedicated connection, bound all I/O and avoid logging secret-bearing inputs.

The underlying reader is synchronous and must run in an isolated worker, never in the UI
or a GLib dispatch callback. Its per-call and total deadlines, path validation,
and device/profile/access-point limits bound the work. Calls target the unique
owner and verify the well-known name before and after the read. The future
service must independently track owner generations and discard results whenever
the generation changes, including a loss and reacquisition by the same unique
owner. It must also discard results from superseded requests.

The reader extracts only the properties needed for the existing state and never
requests `GetSecrets`. Read errors omit remote error text. An inaccessible access
point or saved profile can disappear during a scan and is skipped; malformed,
oversized, foreign or stale data fails the whole snapshot. No writes, scans,
connections or radio changes occur.

`examples/private_snapshot.rs` requires an explicit test bus. The integration
suite `tests/test_network_snapshot_rust.py` uses a private D-Bus and synthetic
NetworkManager to compare the existing Python output and exercise owner loss,
deadlines and malformed data. `examples/private_worker.rs` additionally tests
the scheduler with a dedicated connection to that same private bus. These
tests must never use the real system bus.

`radio::set_power` is a separate user-requested operation, not part of a
snapshot. Run it on a dedicated worker and serialize power commands. It checks
the owner and hardware state, writes `WirelessEnabled` at most once, then
confirms the state and owner. After `Uncertain`, the caller must close the
dedicated connection and must not automatically retry: a timed-out write may
still take effect. The caller must also fence results by the owner generation.
`examples/private_radio.rs` and `tests/test_network_radio_rust.py` use only an
explicit private bus and synthetic NetworkManager.

`radio::scan` validates the device list before dispatch and requests one scan
per Wi-Fi device with empty options. Its success means requests were accepted,
not that results have arrived. The owning service must react to later changes
and refresh the snapshot. Partial, failed or ambiguous dispatch is `Uncertain`;
close the connection and do not automatically repeat it. Serialize scanning
with other Wi-Fi actions and fence results by owner generation.

`activate::saved` dispatches at most one saved-profile activation after
re-reading the selected AP, raw SSID, security, profile and UUID. This recheck
is not atomic against other clients. The returned active-connection path is
explicitly marked as having no proven exclusive owner. `activate::inspect`
reads its state without mutation. After an uncertain activation, close the
dedicated connection and do not retry automatically. The caller still has to
fence owner generations and observation IDs, apply operation deadlines and
coordinate cancellation with `network-core::activation`. These calls are not
yet wired to MacShell. Tests use `examples/private_activate.rs` on a private bus.

`profile::build` validates and constructs a typed NetworkManager settings
variant without sending it. For secured networks the variant contains the
password; it must never be logged, and the caller must drop it and erase its
own copy promptly. The helper wipes its temporary C-string copy, but cannot
guarantee erasure of copies held by GLib or D-Bus. It does not create a profile,
activate a connection, or manage ownership and cancellation.

`activate::create` verifies the selected unsaved network before issuing one
`AddAndActivateConnection2` call with a disk-persisted profile. As with saved
activation, preflight is not atomic, owner epochs must be fenced, and an
uncertain reply must not be retried. It never claims exclusive ownership of the
result. The caller must prepare the operation-scoped secret agent first, supply
the actual desktop username and a fresh CSPRNG UUID, and manage all secret
copies and cancellation. The private-bus integration tests connect this call
to the synthetic SecretAgent and test cancellation during a secret request.
