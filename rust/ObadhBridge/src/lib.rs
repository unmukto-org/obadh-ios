//! Static-link shim for the Obadh engine's C ABI (v2).
//!
//! The engine (`obadh_engine`) owns and defines the entire FFI surface under its
//! `cabi` feature — see the vendored `include/obadh.h`. This crate adds nothing
//! to that surface; it exists only so the engine's `#[no_mangle]` C symbols land
//! in a **staticlib** (`.a`) the iOS xcframework can bundle. The engine itself
//! builds as `rlib`/`cdylib` only, so a downstream that needs a static archive
//! must wrap it, which is all this is.
//!
//! Why the shim below is necessary: when a staticlib is produced, `rustc` and the
//! linker drop `#[no_mangle]` symbols that come from a *dependency* and are not
//! referenced by the root crate — verified empirically (0 symbols survive an empty
//! root). Taking each symbol's address in a `#[used]` static forces the object
//! that defines it to be retained, so the archive exports it. We reference exactly
//! the symbols the Swift client calls (ABI v2) — nothing it doesn't use.

use obadh_engine::cabi;

/// A table of the engine C-ABI entry points the client links. Never called
/// through — only the presence of these addresses in a `#[used]` static matters,
/// which is what pins the symbols into the staticlib.
#[repr(transparent)]
struct AbiSymbols([*const (); 22]);

// SAFETY: the elements are code addresses that are never dereferenced or
// mutated; the table is immutable and read by nothing. It is `Sync` trivially.
unsafe impl Sync for AbiSymbols {}

#[used]
static KEEP_ALIVE: AbiSymbols = AbiSymbols([
    cabi::obadh_abi_version as *const (),
    cabi::obadh_engine_version as *const (),
    cabi::obadh_engine_new as *const (),
    cabi::obadh_engine_free as *const (),
    cabi::obadh_transliterate as *const (),
    cabi::obadh_autocorrect_open as *const (),
    cabi::obadh_autocorrect_free as *const (),
    cabi::obadh_autocorrect_fingerprint as *const (),
    cabi::obadh_autocorrect_word_frequency as *const (),
    cabi::obadh_autocorrect_suggest_detailed as *const (),
    cabi::obadh_compose_suggestions as *const (),
    cabi::obadh_autocorrect_word_alternatives as *const (),
    cabi::obadh_autosuggest_open as *const (),
    cabi::obadh_autosuggest_free as *const (),
    cabi::obadh_autosuggest_fingerprint as *const (),
    cabi::obadh_autosuggest_commit as *const (),
    cabi::obadh_autosuggest_suggest as *const (),
    cabi::obadh_autosuggest_suggest_for_context as *const (),
    cabi::obadh_autosuggest_clear_session as *const (),
    cabi::obadh_autosuggest_clear_personal as *const (),
    cabi::obadh_autosuggest_export_personal as *const (),
    cabi::obadh_autosuggest_import_personal as *const (),
]);
