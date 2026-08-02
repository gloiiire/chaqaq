//! Import diagnostics — **debug builds only**.
//!
//! The Notion importer emits a running log to `<covers_dir>/notion-debug.log`
//! to make link-rewriting and block-promotion decisions inspectable. Those
//! lines carry **verbatim note titles and paragraph text**, and the Swift
//! side copies the file into the app's Documents folder, which is exposed in
//! the Files app. The `eprintln!` variants are just as bad: stderr is
//! captured in sysdiagnose bundles, which users routinely email to support.
//!
//! So the whole facility is gated on `debug_assertions`. [`enabled`] is a
//! `const fn` returning a compile-time constant, which lets the optimizer
//! drop every guarded block — including the string formatting that would
//! have produced the note content — out of release binaries entirely.

/// Whether import diagnostics are compiled in. `false` in release.
///
/// Guard any diagnostic work with this, not just the write itself — the
/// point is that the *formatting* of note content never happens either.
#[inline]
pub(crate) const fn enabled() -> bool {
    cfg!(debug_assertions)
}

/// Appends one line to `<dir>/notion-debug.log`. No-op in release, and
/// no-op when the caller has no covers directory.
///
/// Best-effort: a diagnostics failure must never fail an import.
#[inline]
pub(crate) fn log(dir: Option<&str>, line: &str) {
    if !enabled() {
        return;
    }
    use std::io::Write;
    let Some(dir) = dir else { return };
    let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{dir}/notion-debug.log"))
    else {
        return;
    };
    let _ = writeln!(f, "{}", line.trim_end());
}

/// Mirrors a diagnostic line to stderr. No-op in release — stderr ends up
/// in sysdiagnose bundles.
#[inline]
pub(crate) fn console(line: &str) {
    if !enabled() {
        return;
    }
    eprintln!("{}", line.trim_end());
}
