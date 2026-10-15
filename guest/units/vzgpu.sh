# profile.d: shells (SSH, `vzgpu run`) get the same environment as user services.
if [ -n "$XDG_RUNTIME_DIR" ] && [ -z "$WAYLAND_DISPLAY" ]; then
    set -a; . /etc/environment.d/50-vzgpu.conf; set +a
fi
