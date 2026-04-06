# Text Expander - Linear-Style TODOs

Date baseline: 2026-04-06

## P0 (Ship minimal usable version)

- [x] `TXT-1` Bootstrap Zig app skeleton and CI-friendly build command.
- [x] `TXT-2` Implement Windows keyboard capture loop (low-level hook).
- [x] `TXT-3` Implement trigger matcher and expansion pipeline (`:bb` -> `be right back.`).
- [x] `TXT-4` Add SQLite storage, schema migration, and default seed snippet.

## P1 (Production hardening)

- [ ] `TXT-5` Add robust key mapping for non-US layouts and Unicode support.
- [ ] `TXT-6` Add structured logging and event telemetry table.
- [x] `TXT-7` Add safety guards (max expansion length, recursion prevention, overflow handling).
- [ ] `TXT-8` Add test matrix: unit tests + manual E2E protocol across target apps.

## P2 (Enterprise readiness)

- [ ] `TXT-9` Packaging and install/uninstall flow with run-at-login option.
- [ ] `TXT-10` Security and release gate aligned to SSDF/ASVS checklist subset.
- [ ] `TXT-11` Operational runbook (support diagnostics, known limitations, rollback).

## Agent Team Split

- Team A (Runtime/Core): `TXT-1`, `TXT-2`, `TXT-3`, `TXT-7`
- Team B (Data/Security): `TXT-4`, `TXT-6`, `TXT-10`
- Team C (QA/Release): `TXT-8`, `TXT-9`, `TXT-11`
