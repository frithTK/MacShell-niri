# Requirements for input-profile transactions

This is a design constraint for future work, not an implemented transaction or
permission to write the active profile. `renameat2(RENAME_EXCHANGE)` is atomic
for one pair of names; a profile spanning several files is not atomic. Niri may
observe or reload an intermediate profile. An unrelated editor may race any
check or rename, and the advisory lock does not stop it.

## Proposed architecture: one managed input fragment

For the first integration, ordinary preference updates may replace only the
installer-generated `macshell-input.kdl`. The complete source and proposed
profile must be checked, including all reachable includes. If another file
contains any MacShell-managed input setting, or syntax cannot be analyzed
conservatively, refuse the update and identify the affected file; never strip
or migrate the user's configuration automatically. An unrecognized or edited
generated fragment must likewise be preserved and reported. A separate,
explicit migration workflow may be designed later. The existing multi-file
coordinator is experimental and is not the first integration path.

The installer currently appends an include for the fragment to `config.kdl`.
An isolated `niri validate` fixture on niri 26.04 accepts both distinct input
blocks and a duplicate `mouse.accel-speed` in an included file. Validation
alone therefore does not prove absence of duplicates or which value takes
effect for the managed mouse options. In a disposable nested niri 26.04,
`scripts/check-niri-input-nested.py` observed that a duplicate XKB layout in
the included file took precedence over the root layout and that an atomically
replaced include was automatically reloaded (Russian changed to German as
reported by keyboard-layouts IPC). This does not establish mouse-setting
precedence or prove that the managed settings were applied.
An atomic replacement of one pathname is still not a compare-and-swap and
does not prevent or safely undo an uncooperative concurrent editor's writes.

## Restart evidence and allowed actions

This table defines the initial fail-closed policy, not implemented recovery.
No automatic reverse exchange or cleanup is authorized after an unknown
interruption merely because these observations match.

| Evidence after reopening | Interpretation | Permitted action |
| --- | --- | --- |
| No transaction artifacts | No remaining evidence; not proof that no prior event happened | Begin only after normal profile and orphan checks. |
| Candidate without manifest | Creation may have stopped before manifest persistence | Preserve and report it; do not infer ownership or delete automatically. |
| Manifest without progress, damaged record, gap or unexpected name | Incomplete or untrusted evidence | Block new writes; preserve artifacts and report diagnostics. |
| Empty progress and matching original/candidate | No recorded intent; observation may be stale | Preserve both; stop for inspection. |
| Intent with original/candidate or exchanged arrangement | Exchange may or may not have happened before interruption | Preserve both; do not repeat or reverse automatically. |
| Completion with matching exchanged arrangement | Records and observed arrangement agree; authenticity and prior fsync are unproven | Preserve evidence; require explicit conflict-aware resolution. |
| Missing or changed file, unsupported metadata, or disagreement | Conflict or insufficient evidence | Stop and preserve all available versions. |
| Completion or cleanup interrupted | Some artifacts may already be absent | Report the observed state; do not infer permission to remove remaining files. |

The eventual diagnostic must identify the profile and available versions and
provide a documented way to compare and validate a user-selected configuration
in isolation. Observed file, durable write, and compositor-applied state are
separate outcomes. A restart, matching inode, hash, or successful validation
alone does not establish provenance or permit a write.

## Before an exchange

- Hold the cooperative profile lock and verify its identity throughout the
  operation. Validate both source and proposed profiles, and verify the source
  snapshot again before starting. Do not treat this as an atomic comparison.
- Construct replacement files in their target directories using anchored
  directory descriptors and exclusive names; do not follow links. Preserve or
  explicitly reject unsupported attributes. The current primitive rejects
  visible xattrs but cannot prove inaccessible attributes are absent.
- Persist replacement data and required metadata, then synchronize the
  containing directories. Retain the old and new file versions through every
  exchange. Secure temporary names and journal contents against disclosure and
  replacement; account for abandoned files created before a journal exists.
- Before the first exchange, durably record a versioned, bounded transaction
  manifest with profile identity, each relative target and candidate name,
  expected versions and attributes, and enough evidence to detect corruption.
  Journal updates must themselves be crash-safe and their directory synced.
  Paths read from a journal are untrusted and must never permit escape from the
  profile or traversal through symlinks.

## Applying and recovering

- Persist intent for each exchange before issuing it. After an exchange,
  synchronize its parent directory before recording durable progress. An
  error or crash between these steps can leave either arrangement; the journal
  alone cannot identify what happened. An `Uncertain` or `DurabilityUnknown`
  result must never be reported as success or trigger blind deletion.
- After restart, reopen the journal and both names through checked directory
  descriptors, and examine all available evidence. Inode numbers alone are not
  durable proof: files can be replaced or inode numbers reused. Missing,
  changed or ambiguous data, including inaccessible metadata, must stop
  automatic recovery and preserve all remaining versions for inspection.
- Even a matching observation can become stale immediately. Do not claim that
  revalidation or an automatic reverse exchange makes uncooperative concurrent
  writes safe. Define and test exactly when recovery is allowed, and surface
  unresolved conflicts to the caller without overwriting external edits.
- Treat partially applied multi-file changes and niri's intermediate reloads
  explicitly. Decide whether a different layout can reduce the live switch to
  one atomic name change; otherwise describe the observable intermediate state
  and do not promise all-or-nothing visibility.
- Mark completion durably before any cleanup. Never remove a backup or journal
  merely because a prior in-memory step succeeded. Cleanup itself needs a
  crash-safe, conflict-aware protocol.

## Required evidence before integration

Test failures and process termination at every persistence boundary, missing
and substituted names, in-place edits and metadata changes, journal corruption,
unsupported filesystems, validator failure and concurrent non-cooperating
writers. Verify file and directory synchronization ordering. Run end-to-end
tests only on disposable profiles, including actual niri validation and reload
behavior, before considering launcher or installer integration.
