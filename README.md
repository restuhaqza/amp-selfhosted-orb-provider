# Self-hosted Amp orbs on one Docker host

Runs `amp orb provider` on your own machine so Amp threads execute on orbs inside
your infrastructure. Orbs boot a minimal **systemd** base image inside
**unprivileged** sysbox containers — no `--privileged`, no host cgroup or device
mounts.

```diagram
┌──────────────┐   jobs    ┌──────────────┐   docker   ┌─────────────────────┐
│ ampcode.com  │◀────────▶ │ amp orb      │──────────▶ │ orb container       │
│              │  HTTPS    │ provider     │ dispatch.sh│ (sysbox-runc)       │
└──────────────┘           └──────────────┘            │ systemd = PID 1     │
        ▲                                              │ user = uid 1000     │
        └──────────── amp orb bootstrap ───────────────└─────────────────────┘
```

## Contents

| Path | Purpose |
| --- | --- |
| `dispatch.sh` | Dispatch program the provider runs once per job (`spawn`, `pause`, `delete`). |
| `image/Dockerfile` | Base image with systemd as PID 1, 488MB instead of Amp's 4.16GB orb image. |
| `systemd/amp-orb-provider.user.service` | Per-user unit (no root, `Linger=yes` keeps it up across reboots). |
| `systemd/amp-orb-provider.system.service` | System unit alternative, for hosts with no login session (see below). |
| `systemd/orb-provider.env.example` | Template for the provider environment file. |

## Requirements

- Docker with `sysbox-runc`. **sysbox-ce 0.7.1 or later is required with Docker 29.5+:**
  Docker enabled private time namespaces by default, and sysbox ≤ 0.7.0 rejects them
  with `namespace {"time ""} does not exist` on every `docker run`.
- The `amp` CLI on the host, logged in.
- A provider token from **Settings → Orbs → Add Orb Provider** (shown once, `aop_live_…`).

## Setup

### 1. Provider environment

```bash
mkdir -p ~/.config/amp
cp systemd/orb-provider.env.example ~/.config/amp/orb-provider.env
chmod 600 ~/.config/amp/orb-provider.env
$EDITOR ~/.config/amp/orb-provider.env      # paste the aop_live_… token
```

### 2. Dispatch program

```bash
install -m 755 dispatch.sh ~/.amp/orbs/dispatch.sh
```

### 3. Service

User unit, which needs no root:

```bash
install -m 644 systemd/amp-orb-provider.user.service ~/.config/systemd/user/
loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now amp-orb-provider
```

`systemctl --user` needs `XDG_RUNTIME_DIR`. If your shell has none (no logind
session, e.g. access over a channel that skips PAM), you get
`Failed to connect to bus: No medium found`. Either prefix commands with
`XDG_RUNTIME_DIR=/run/user/$(id -u)`, or use the system unit instead:

```bash
sudo sed "s/CHANGE_ME/$USER/g" systemd/amp-orb-provider.system.service \
  | sudo tee /etc/systemd/system/amp-orb-provider.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now amp-orb-provider
```

Run one provider per token. Stop the user unit before starting the system one.

### 4. Optional: the systemd base image

```bash
docker build -t amp-orb-systemd:latest image/
echo 'ORB_IMAGE=amp-orb-systemd:latest' >> ~/.config/amp/orb-provider.env
systemctl --user restart amp-orb-provider
```

Changing `ORB_IMAGE` affects new orbs only. Existing orbs and snapshots keep the
image they started from.

## Why the image is built this way

Amp's own orb image is Debian 12 and already contains systemd, but boots
`python3` as PID 1. This image boots `/sbin/init` instead, which is what lets Amp
manage long-lived services with `systemctl` inside the orb.

Requirements follow [Bring Your Own Image](https://ampcode.com/docs/orbs/self-hosted#bring-your-own-image):
bash, coreutils, util-linux, CA certificates, git ≥ 2.34 at `/usr/bin/git`, the
`amp` binary at `/usr/local/bin/amp`, a `user` account (uid 1000) with a writable
`/home/user` and passwordless sudo, node ≥ 18, tmux ≥ 2.9, curl, plus ripgrep, gh
and openssh-client. The base must be glibc, so Alpine does not work.

Two details that matter:

- **`--init` is not used.** systemd is PID 1, so a separate init process would
  break it.
- **The container runs with `--user root`** so `/sbin/init` can start, while
  `docker exec` runs `amp orb bootstrap` with `--user user`, which is what the
  dispatch contract asks for.
- `STOPSIGNAL SIGRTMIN+3` lets `docker stop` hand systemd a clean power-off
  (~1s, exit code 0) instead of killing it after the timeout.

Units that need host kernel access (`sys-kernel-config.mount`,
`sys-kernel-debug.mount`, `sys-kernel-tracing.mount`, `kmod-static-nodes.service`)
are masked by symlinking to `/dev/null`. `systemctl mask` cannot be used during a
build because no systemd is running there. Without the mask, `systemctl
is-system-running` reports `degraded` for failures that are unavoidable in an
unprivileged container.

## Privileged containers are not needed

sysbox gives the container its own user namespace, so in-orb root is not host root:

```
sysbox-runc   uid_map: 0  165536  65536      # PID 1 maps to host uid 165536
runc          uid_map: 0  0  4294967295      # container root IS host root
```

Measured on the orb container: `privileged=false`, `capadd=[]`, `devices=[]`,
`runtime=sysbox-runc`. Dropping sysbox would weaken isolation, not improve it.

## Verification

```
PID 1                 root systemd
systemctl is-system-running   running        (0 failed units)
docker exec --user user id    uid=1000(user)
pause                 exit code 0, snapshot committed
resume                systemd boots again
delete                container removed
amp orb bootstrap     runs as user, reaches Amp
```

## Limitations

- **Desktop** is unavailable: it needs `/opt/amp-wayland`, xwayland, dbus-x11,
  pulseaudio and ffmpeg from Amp's image. Portals and Terminal work.
- **No nested Docker**: Amp's image puts `user` in the `docker` group; this one does not.
- **Node 18** instead of 26. Add a newer release if an external agent needs it.
- **Memory is not preserved** on pause, so services behind portals restart when
  the orb wakes and Terminal sessions are lost. Disk is preserved, so a waking
  orb runs `.agents/resume`, not `.agents/setup`.

## Security notes

`~/.config/amp/orb-provider.env` holds the provider token. Keep it mode 600 and
never commit it; `.gitignore` covers `*.env`. The system unit is read by root, so
the file can stay owned by your user.
