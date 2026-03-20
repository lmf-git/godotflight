// build.rs — Re-runs whenever Cargo.toml changes so cargo knows to re-link.
// The .gdextension file points directly at rust/target/debug/ and rust/target/release/
// so no file copying is needed — Godot loads from the cargo output directory automatically.
fn main() {
    println!("cargo:rerun-if-changed=Cargo.toml");
}
