# Niri input configuration migration

This crate contains configuration transformations, a bounded profile snapshot,
validation in a private temporary directory, a cooperative lock and the Rust
input service used by the shell. The service performs a single-file transaction
with a durable journal, progress snapshots and explicit recovery cleanup.
The binary exposes `diagnose <journal>` for read-only JSON diagnostics and
`resolve-cleanup <journal>` for explicit cleanup after a diagnostic reports
`cleanupAllowed: true`.
Taking the lock can create a private lock file in a profile. The launcher selects
the compatible Rust service and falls back to `niri_tools.py` when it is absent or
incompatible.

The service intentionally limits writes to the managed single-file fragment.
Snapshots are not atomic and are revalidated before committing; path and identity
checks cannot by themselves provide an atomic compare-and-swap. Staged validation
conservatively rejects external or ambiguous includes and several unsupported KDL
constructs.
It accepts LF and CRLF, but conservatively rejects standalone CR, form feed,
NEL, Unicode line separator and paragraph separator anywhere in a file. Niri
interprets these characters as node boundaries, which the byte scanner does
not otherwise handle.
`prepare_single` and `prepare_single_locked` check the source profile with the
validator, refuse plans that would alter files outside the managed input
fragment, and validate the proposed profile in a private temporary directory.
The fragment must be reachable exactly once from `config.kdl`; cycles and
repeated reachable include paths are conservatively rejected.
Single-fragment preparation rejects reserved `.macshell-input-` artifact names
anywhere in the traversed profile, including incomplete or malformed names;
it preserves them and repeats the check when rechecking a prepared snapshot.
This is only a point-in-time observation; the public `diagnose` command exposes
the same evidence without authorizing a reverse exchange.
The locked variant retains an advisory lock and can create its lock file; it
does not commit the plan or prevent uncooperative edits.
The transformation rejects managed nodes whose removal would discard or split
comments. The generated fragment is replaced only when it exactly matches the
installer's initial placeholder or a recognized canonical generated fragment;
other content is rejected for the user to resolve. This does not prove who
edited a fragment that happens to match the generated format.
The include analysis and lexer need further compatibility and adversarial
testing before they can protect writes to a real profile. The advisory lock
serializes only cooperating Rust writers, not Python or other editors. File
exchange retains both names and detects some conflicts after a swap, but an
unexpected result may already have changed the target pathname. It must not
be treated as a compare-and-swap or used for real profile writes without a
complete recovery strategy. Restart handling is fail-closed: retained evidence
blocks a new write, `diagnose` reports it, and only explicit cleanup of a
consistent, fully exchanged transaction can remove evidence. No automatic
rollback is performed.
The exchange detects changes to basic mode, owner, group and link count during
the operation; the future caller must check snapshot attributes before exchange
and preserve them on the replacement. The primitive rejects files with visible
extended attributes, including Linux ACLs, and fails closed if listing them
fails. Visibility may be restricted and changes can race the checks; this does
not establish that hidden attributes are absent or safely preserved.
`journal` provides a size-bounded manifest codec with strict path and metadata
checks. The experimental `journal_store` can create and read a private manifest,
but has no integrity authentication or recovery behavior.
It stores both versions' contents and may use substantial memory. A valid
manifest is not proof that it is trustworthy; access control, metadata, crash
and concurrent replacement handling require further work before integration.
`recovery::inspect` can reopen and compare names to a manifest for diagnosis,
but returns racy observations only: a match does not establish provenance or
authorize cleanup, rollback or any other write.
The report distinguishes fully original, fully exchanged, partially exchanged
and conflicting observations; its per-file checks do not form an atomic view.
`recovery::compare_progress` compares those observations with a ledger bound to
the manifest, and detects disagreements or an exchange with outstanding intent.
It is diagnostic only; agreement neither authenticates records nor authorizes
automatic recovery, cleanup or further writes. The public command exposes the
diagnostic state and cleanup only after the same checks are repeated under the
lock.
`recovery::inspect_journal` combines the saved manifest and progress chain with
file observations, and rechecks the saved evidence after inspection. Its
results remain non-atomic and cannot establish authenticity or durability.
The public `diagnose` command holds the cooperative lock while producing the
same report. Cleanup is allowed only for a consistent, fully exchanged
transaction; pending or conflicting transactions remain blocked and all
artifacts are preserved.
`progress` models ordered intent and completion events bound to an exact
manifest by SHA-256. `progress_store` experimentally stores immutable snapshots
of those events. A separate scan checks the supported sequence for gaps and
malformed records, and the writer checks the existing chain before extending
it. A gap, malformed snapshot name or out-of-range snapshot blocks further
writes. The scan cannot detect a missing final suffix or prove fsync succeeded. Restart handling is unfinished;
the hash does not authenticate the data and event presence does not prove
filesystem state.
`staging` experimentally creates a synchronized candidate with basic owner,
group and mode checks. It needs an anchored, trusted parent and an independently
revalidated profile snapshot; it is not connected to profile transactions.
Only visible xattrs are checked, and races and interrupted staging can leave
candidate files that require inspection.

Run `cargo test --locked --offline --manifest-path native/niri-input/Cargo.toml`.
The `compat` example supports comparison with the current Python implementation;
`tests/test_niri_input_rust.py` uses it with temporary inputs only.
