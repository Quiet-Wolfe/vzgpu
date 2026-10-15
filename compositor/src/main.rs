//! vzcomp: a Wayland compositor that turns each Linux app into a native macOS app.
//!
//!   vzcomp [--socket PATH]   listen; every connection gets its own app process
//!   vzcomp --client-fd N     (internal) serve one connected client as one macOS app
//!
//! One process per Wayland connection is what gives every Linux app its own Dock icon,
//! menu bar, Cmd-Tab entry and fullscreen Space: macOS ties those to processes.

macro_rules! log {
    ($($t:tt)*) => {{
        eprintln!("[vzcomp {}] {}", std::process::id(), format!($($t)*));
    }};
}

mod comp;
mod handoff;
mod mac;

use std::os::fd::AsRawFd;
use std::os::unix::net::UnixListener;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;

pub fn default_socket() -> PathBuf {
    // The per-user temp dir (what NSTemporaryDirectory returns), not $TMPDIR, which
    // shells and sandboxes override.
    let mut buf = vec![0u8; 1024];
    let n = unsafe { libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buf.as_mut_ptr() as *mut _, buf.len()) };
    let dir = if n > 0 && n <= buf.len() {
        String::from_utf8_lossy(&buf[..n - 1]).into_owned()
    } else {
        std::env::temp_dir().to_string_lossy().into_owned()
    };
    PathBuf::from(dir).join("vzcomp").join("wayland-0")
}

fn serve(socket: PathBuf) -> ! {
    if let Some(dir) = socket.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap_or_else(|e| {
        log!("bind {}: {e}", socket.display());
        std::process::exit(1)
    });
    unsafe { libc::signal(libc::SIGCHLD, libc::SIG_IGN) };  // children are reaped automatically
    log!("listening on {}", socket.display());
    let claims = handoff::listen(&socket);
    let exe = std::env::current_exe().expect("current_exe");
    for conn in listener.incoming() {
        let stream = match conn {
            Ok(s) => s,
            Err(e) => {
                log!("accept: {e}");
                continue;
            }
        };
        let fd = stream.as_raw_fd();
        if handoff::hand_to_claimant(&claims, fd) {
            continue;  // a launcher bundle serves it (drop closes our copy)
        }
        let mut cmd = Command::new(&exe);
        cmd.arg("--client-fd").arg(fd.to_string());
        unsafe {
            cmd.pre_exec(move || {
                // Let the client socket survive exec.
                let flags = libc::fcntl(fd, libc::F_GETFD);
                libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC);
                Ok(())
            });
        }
        match cmd.spawn() {
            Ok(child) => log!("connection -> app process {}", child.id()),
            Err(e) => log!("spawn: {e}"),
        }
        drop(stream);  // the child owns its copy
    }
    std::process::exit(0);
}

/// xkbcommon's keymap data ships in vzgpu.app (Contents/Resources/xkb). Launcher bundles
/// (/Applications/<distro>/<App>.app) find it through the CLI path they carry.
fn use_bundled_xkb() {
    if std::env::var_os("XKB_CONFIG_ROOT").is_some() {
        return;
    }
    let Ok(exe) = std::env::current_exe() else { return };
    let contents = exe.parent().and_then(|p| p.parent()).map(PathBuf::from);
    let mut candidates = Vec::new();
    if let Some(c) = &contents {
        candidates.push(c.join("Resources/xkb"));
        if let Ok(cli) = std::fs::read_to_string(c.join("Resources/vzgpu-cli")) {
            if let Some(app_contents) = std::path::Path::new(cli.trim()).parent().and_then(|p| p.parent()) {
                candidates.push(app_contents.join("Resources/xkb"));
            }
        }
    }
    if let Some(dir) = candidates.into_iter().find(|d| d.is_dir()) {
        std::env::set_var("XKB_CONFIG_ROOT", dir);
    }
}

fn main() {
    use_bundled_xkb();
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--client-fd") => {
            let fd: i32 = args.get(2).and_then(|s| s.parse().ok()).expect("--client-fd N");
            comp::run_client(fd);
        }
        Some("--socket") => serve(PathBuf::from(args.get(2).expect("--socket PATH"))),
        // A launcher bundle's executable (/Applications/<distro>/<App>.app) is this binary.
        None => match handoff::bundle() {
            Some(b) => handoff::run_launcher(b, &default_socket()),
            None => serve(default_socket()),
        },
        Some(other) => {
            eprintln!("usage: vzcomp [--socket PATH]\n(unknown argument {other})");
            std::process::exit(2);
        }
    }
}
