# SQLSetupTool — Changelog

## [Unreleased] — 2026-07-13

### Added delayed autostart for SQL services when running on a VM

## [Unreleased] — 2026-07-10

### Added per-domain option to enable/disable maintenance & backup job install

## [Unreleased] — 2026-07-05

### Fix: install pipeline crashes; added domain-profile/TempDB overrides

### Fix: versions comma-split bug

Added a PS2EXE feasibility test for FI-TS.

## [Unreleased] — 2026-06-22

### Checkpoint/resume for install and PostInstall phases

An aborted run now continues instead of repeating already-completed steps, for both the CLI and
GUI, with a `-Force` override. PostInstall step 5 now actually sets `msdb` (and `model`) to FULL
recovery. GUI: applied the Visual Studio "Dark" theme to all SQLSetupTool forms. Docs: consolidated
technical manual covering both GUI and CLI.

## [Unreleased] — 2026-06-20

### Headless CLI setup + animated progress report

### Fix: GUI shows startup errors instead of silently closing

### Fix: StrictMode "property Count cannot be found" error in some domains

## [Unreleased] — 2026-06-08

### Added Qualys monitoring access as an optional PostInstall step

## [Unreleased] — 2026-05-28 to 2026-05-29

### Added driver version comparison and HPU check (PreInstall Check 4)

### SSRS: wildcard installer, edition/product key, configuration via sqmSQLTool

## [Unreleased] — 2026-05-26 to 2026-05-27

### Configuration GUI (ConfigForm / DomainConfigForm)

`ConfigForm` for `settings.ini` configuration, later extended with a `PropertyGrid` for tabs 1 and
3 plus Power BI settings. Domain-profile support with role separation (Anwender/Admin/Domain-Admin),
with a README section documenting the configuration process for all three roles. Renamed
`ZielBasePath` to `SQLSourcesPath`, wired in as a source-share override in the setup flow. Several
follow-up fixes: PS 5.1 CodeDom C# 4.0-compatible syntax, arrow-character and array-index bugs in
`DomainConfigForm`, missing `[void]` casts on dynamically added controls, starter-script and
hint-label positioning, and dialog sizing so buttons are no longer cut off.

### Install phases 2–7

Drivers, ports, and PreInstall/PostInstall sections in config; `Drivers.psm1` and
`PreInstall.psm1`; driver checkboxes, TCP port display, and PreInstall/PostInstall TCP port
handling. Path validation on GUI startup. Extended `New-SqlSourceStructure` with a centralized
source structure, README placeholders, and an FI-TS variant; source structure extended to match
FI-TS component alignment.

## [Unreleased] — 2026-05-20 to 2026-05-23

### Added New-SqlSourceStructure.ps1

Creates the SQLSources folder tree from `settings.ini`.

### Added company SQL script execution in PostInstall

Runs `*.sql` files from a Scripts folder.

### Added Step 18 — setup completion report

Via `Invoke-sqmSetupReport`.

### Added Start-SQLSetupTool.cmd

A unified starter script.

### Docs

15-slide Reveal.js presentation.

## [1.0] — 2026-05-18

### Initial release

SQL Server automated setup tool, MIT-licensed.
