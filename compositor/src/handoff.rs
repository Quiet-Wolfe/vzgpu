//! Launcher handoff: a Linux app's launcher bundle (/Applications/<distro>/<App>.app, whose
//! executable is a copy of vzcomp) *becomes* that app's process, so the Dock tile, pinning,
//! Cmd-Tab and the app name all belong to the bundle.
//!
//! The broker only learns which app a Wayland connection belongs to after the client has bound
//! globals and made windows; that state can't move between processes. So the launcher claims
//! the connection beforehand: it tells the broker's control socket `claim <app>`, starts the app
//! in the guest, and the broker passes it the next Wayland connection (SCM_RIGHTS). Guest apps'
//! own connection arrives first; the short-lived helper connections that follow go to
//! per-connection children as before. A claimed connection that closes before mapping a window
//! makes the launcher claim again (it re-execs: same pid, same Dock tile).
//!
//! Running apps leave `<dir>/apps/<desktop-id>.pid`, so launching an app that is already running
//! (GTK apps are single-instance: no new connection) activates it instead.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

pub type Claims = Arc<Mutex<VecDeque<(String, UnixStream)>>>;

pub fn control_path(socket: &Path) -> PathBuf {
    socket.with_file_name("control")
}

fn running_dir(socket: &Path) -> PathBuf {
    socket.with_file_name("apps")
}

/// Broker side: accept claims on the control socket.
pub fn listen(socket: &Path) -> Claims {
    let claims: Claims = Arc::default();
    let path = control_path(socket);
    let _ = std::fs::remove_file(&path);
    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            log!("control socket {}: {e}", path.display());
            return claims;
        }
    };
    let queue = claims.clone();
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let mut line = String::new();
            if BufReader::new(&conn).read_line(&mut line).is_err() {
                continue;
            }
            if let Some(app) = line.trim().strip_prefix("claim ") {
                log!("claim for {app}");
                queue.lock().unwrap().push_back((app.to_string(), conn));
            }
        }
    });
    claims
}

/// Broker side: give `fd` to the oldest live claim. False if nobody is waiting.
pub fn hand_to_claimant(claims: &Claims, fd: RawFd) -> bool {
    let mut q = claims.lock().unwrap();
    while let Some((app, conn)) = q.pop_front() {
        if send_fd(&conn, fd).is_ok() {
            log!("connection -> launcher for {app}");
            return true;
        }
        // The launcher gave up (timed out or quit); try the next one.
    }
    false
}

fn send_fd(conn: &UnixStream, fd: RawFd) -> std::io::Result<()> {
    unsafe {
        let mut byte = 0u8;
        let mut iov = libc::iovec { iov_base: &mut byte as *mut u8 as *mut _, iov_len: 1 };
        let space = libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) as usize;
        let mut cbuf = vec![0u8; space];
        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cbuf.as_mut_ptr() as *mut _;
        msg.msg_controllen = space as _;
        let cmsg = libc::CMSG_FIRSTHDR(&msg);
        (*cmsg).cmsg_level = libc::SOL_SOCKET;
        (*cmsg).cmsg_type = libc::SCM_RIGHTS;
        (*cmsg).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32) as _;
        std::ptr::write_unaligned(libc::CMSG_DATA(cmsg) as *mut RawFd, fd);
        if libc::sendmsg(conn.as_raw_fd(), &msg, libc::MSG_NOSIGNAL) == 1 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        }
    }
}

fn recv_fd(conn: &UnixStream) -> std::io::Result<RawFd> {
    unsafe {
        let mut byte = 0u8;
        let mut iov = libc::iovec { iov_base: &mut byte as *mut u8 as *mut _, iov_len: 1 };
        let space = libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) as usize;
        let mut cbuf = vec![0u8; space];
        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cbuf.as_mut_ptr() as *mut _;
        msg.msg_controllen = space as _;
        let n = libc::recvmsg(conn.as_raw_fd(), &mut msg, 0);
        if n <= 0 {
            return Err(if n == 0 {
                std::io::ErrorKind::UnexpectedEof.into()
            } else {
                std::io::Error::last_os_error()
            });
        }
        let cmsg = libc::CMSG_FIRSTHDR(&msg);
        if cmsg.is_null() || (*cmsg).cmsg_type != libc::SCM_RIGHTS {
            return Err(std::io::ErrorKind::InvalidData.into());
        }
        Ok(std::ptr::read_unaligned(libc::CMSG_DATA(cmsg) as *const RawFd))
    }
}

/// App side: record that this process runs `desktop_id` (removed again at exit).
pub fn register_running(socket: &Path, desktop_id: &str) {
    let dir = running_dir(socket);
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join(format!("{desktop_id}.pid"));
    let _ = std::fs::write(&path, std::process::id().to_string());
    let _ = PIDFILE.set(path);
    extern "C" fn cleanup() {
        if let Some(p) = PIDFILE.get() {
            if std::fs::read_to_string(p).ok().as_deref() == Some(&std::process::id().to_string()) {
                let _ = std::fs::remove_file(p);
            }
        }
    }
    unsafe { libc::atexit(cleanup) };
}
static PIDFILE: OnceLock<PathBuf> = OnceLock::new();

fn running_pid(socket: &Path, desktop_id: &str) -> Option<i32> {
    let pid: i32 = std::fs::read_to_string(running_dir(socket).join(format!("{desktop_id}.pid"))).ok()?.trim().parse().ok()?;
    (unsafe { libc::kill(pid, 0) } == 0).then_some(pid)
}

/// The launcher bundle this executable lives in, if any: Contents/Resources/vzgpu-id names the
/// guest app, vzgpu-cli the command that starts it in the guest.
pub struct Bundle {
    pub app: String,
    pub cli: PathBuf,
}

pub fn bundle() -> Option<Bundle> {
    let exe = std::env::current_exe().ok()?;
    let res = exe.parent()?.parent()?.join("Resources");
    let app = std::fs::read_to_string(res.join("vzgpu-id")).ok()?.trim().to_string();
    let cli = PathBuf::from(std::fs::read_to_string(res.join("vzgpu-cli")).ok()?.trim());
    Some(Bundle { app, cli })
}

/// Launcher side: claim the app's connection, start the app, then serve it in this process.
pub fn run_launcher(b: Bundle, socket: &Path) -> ! {
    // Started by LaunchServices, stderr goes nowhere: keep a log next to the share.
    if let Some(f) = std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join("Library/Application Support/vzgpu/launcher.log"))
        .and_then(|p| std::fs::OpenOptions::new().create(true).append(true).open(p).ok())
    {
        unsafe { libc::dup2(f.as_raw_fd(), 2) };
    }
    log!("launcher for {} (reclaim={})", b.app, std::env::var_os("VZGPU_RECLAIM").is_some());
    if let Some(pid) = running_pid(socket, &b.app) {
        log!("{} already running as {pid}; activating it", b.app);
        unsafe { crate::mac::vz_activate_pid(pid) };
        std::process::exit(0);
    }
    // On a reclaim (re-exec) the app is already starting; just claim again.
    let mut started = std::env::var_os("VZGPU_RECLAIM").is_some();
    // Claim before starting the app, so its connection can't arrive unclaimed. If the broker
    // isn't up, start the app anyway (the CLI starts the broker) and keep trying.
    let mut conn = None;
    for _ in 0..300 {
        if let Ok(c) = UnixStream::connect(control_path(socket)) {
            conn = Some(c);
            break;
        }
        if !started {
            start_app(&b);
            started = true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let Some(mut conn) = conn else {
        log!("no vzcomp broker at {}", control_path(socket).display());
        std::process::exit(1);
    };
    if writeln!(conn, "claim {}", b.app).is_err() {
        std::process::exit(1);
    }
    if !started {
        start_app(&b);
    }
    // Long enough for a cold VM boot plus app start.
    let _ = conn.set_read_timeout(Some(Duration::from_secs(120)));
    match recv_fd(&conn) {
        Ok(fd) => {
            let _ = EXPECTED.set(b.app.clone());
            crate::comp::run_client(fd)
        }
        Err(e) => {
            log!("no connection for {}: {e}", b.app);
            std::process::exit(0);
        }
    }
}

fn start_app(b: &Bundle) {
    // `vzgpu launch` boots the VM and compositor if needed and starts the app in the guest.
    let log = std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join("Library/Application Support/vzgpu/launcher.log"))
        .and_then(|p| std::fs::OpenOptions::new().create(true).append(true).open(p).ok());
    let mut cmd = std::process::Command::new(&b.cli);
    cmd.args(["launch", &b.app]).stdin(std::process::Stdio::null());
    if let Some(f) = log {
        cmd.stdout(f.try_clone().map(Into::into).unwrap_or(std::process::Stdio::null()));
        cmd.stderr(f);
    }
    match cmd.spawn()
    {
        Ok(_) => log!("launching {} via {}", b.app, b.cli.display()),
        Err(e) => log!("launch {}: {e}", b.cli.display()),
    }
}

static EXPECTED: OnceLock<String> = OnceLock::new();

/// The app this process was launched for (launcher mode), if any.
pub fn expected_app() -> Option<&'static str> {
    EXPECTED.get().map(String::as_str)
}

/// A claimed connection closed before it showed a window (a helper, not the app): claim again.
/// Re-exec keeps the pid, so LaunchServices and the Dock still see the same launched app.
pub fn reclaim() -> ! {
    log!("claimed connection closed before mapping a window; claiming again");
    let exe = std::env::current_exe().expect("current_exe");
    std::env::set_var("VZGPU_RECLAIM", "1");
    let c = std::ffi::CString::new(exe.as_os_str().as_encoded_bytes()).unwrap();
    unsafe { libc::execv(c.as_ptr(), [c.as_ptr(), std::ptr::null()].as_ptr()) };
    std::process::exit(1);
}
