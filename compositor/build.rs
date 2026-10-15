fn main() {
    println!("cargo:rerun-if-changed=src/mac.m");
    println!("cargo:rerun-if-changed=src/mac.h");
    cc::Build::new()
        .file("src/mac.m")
        .flag("-fobjc-arc")
        .flag("-Wall")
        .compile("vzmac");
    println!("cargo:rustc-link-search=native=/opt/homebrew/lib");
    for f in ["AppKit", "QuartzCore", "IOSurface", "CoreVideo", "Foundation"] {
        println!("cargo:rustc-link-lib=framework={f}");
    }
}
