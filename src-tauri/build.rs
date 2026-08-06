fn main() {
    #[cfg(target_os = "macos")]
    {
        // Link WidgetKit so WidgetCenter is available for timeline reloads.
        println!("cargo:rustc-link-lib=framework=WidgetKit");
    }
    tauri_build::build()
}
