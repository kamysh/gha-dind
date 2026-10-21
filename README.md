# gha-dind — self-hosted CI runner via Docker-in-Docker

A pool of **ephemeral GitHub Actions runners**, each a **Docker-in-Docker (DinD)**
container, that pick up real jobs from a repository you nominate. Every job gets
a fresh runner registration and clean Docker state, then the container is thrown
away — GitHub's one-VM-per-job isolation, at container weight.

Why DinD rather than a microVM fleet: it costs ~nothing when idle and needs no
pre-allocated RAM, which fits bursty CI far better. The runner is a normal Ubuntu
Actions runner — your workflows do not need to know they are not on
`ubuntu-latest`.

**What you get over a hosted runner:** warm Go/npm caches and a warm inner Docker
image cache that persist across jobs, and toolchains baked into the runner
tool-cache so `actions/setup-go` / `setup-node` skip their per-job download.

Agda workflows can also use the persistent `/cache/agda` host bind mount.
The workflow must restore compatible `.agdai` interfaces into its own checkout,
run Agda normally, then save interfaces only after successful checking. Do not
point concurrent Agda processes at one writable build tree. Cache transport and
compiler/library compatibility keys belong to the consuming repository; the
runner only supplies storage. Adding this mount does not require an image
rebuild. Existing runner processes need a separately approved rollout after
their active jobs finish; do not restart the pool to apply it mid-job.

---

## Configure

```sh
cp config.env.example config.env
$EDITOR config.env          # REPO=<owner>/<repo> is required
```

`config.env` is gitignored and is literal `KEY=VALUE` with no shell expansion, so
the same file also works as a systemd `EnvironmentFile=`. Environment variables
override it. See `config.env.example` for every setting.

You also need a **fine-grained PAT** with **repo Administration: read & write** on
the target repo — used *only* to mint runner registration tokens:

```sh
mkdir -p secrets && printf '%s' '<fine-grained-PAT>' > secrets/gh-pat && chmod 600 secrets/gh-pat
```

## Build the image (once)

Runner containers launch **FROM `gha-dind-runner:latest`**, which bakes the base
deps (docker.io, git, curl, build-essential, ca-certificates, libicu74) AND the
extracted GitHub Actions runner agent — installed ONCE at image-build time, not on
every container launch. This is why a job container starts in seconds.

```sh
./build-image.sh
```

Rebuild only when the dep set (`Dockerfile`), the pinned runner version, or the
baked toolchain versions change — **not** per job. `runner.sh` fails fast with a
clear message if the image is missing.

### Baked toolchains

`GO_VERSION` / `NODE_VERSION` in `config.env` are baked into the runner
tool-cache at `/opt/hostedtoolcache/<tool>/<version>/x64`, which is where
`actions/setup-go` and `actions/setup-node` look. The directory is named with the
exact version, but your workflow's request need not be — setup-* resolves its
version spec as a semver range over what is installed, so `go-version: '1.25'`
matches a baked `1.25.12`. Bake a version that *satisfies* what the workflow
asks for. Set either to an empty value to skip that bake;
the job then downloads the toolchain itself, as on a hosted runner. Swap in
whatever toolchains your own matrix needs.

## Run the pool

```sh
./pool.sh            # POOL_SIZE slots from config.env (default 4)
./pool.sh 7          # or an explicit count
```

Size the pool to the width of the matrix you want to run without queuing. A
smaller pool is not an error — jobs just queue.

Point your workflow at the runners with the label from `config.env`:

```yaml
runs-on: [self-hosted, dind]
```

## Layout

- **`Dockerfile`** — `FROM ubuntu:24.04`; apt-installs the base deps once, bakes
  the toolchains into the runner tool-cache and the runner agent tarball into
  `/actions-runner`, copies `runner-entry.sh`.
- **`build-image.sh`** — downloads the pinned runner tarball, `docker build` →
  `gha-dind-runner:latest`.
- **`pool.sh [N]`** — starts N ephemeral runner slots. Each slot is fully isolated
  (own inner dockerd + `/var/lib/docker` volume), so a job's `docker run --name
  postgres -p 5432` never collides across concurrent jobs.
- **`runner.sh <i>`** — one slot's loop: mint a fresh per-job registration token
  from the PAT → launch a runner container that registers **ephemeral** + runs
  exactly ONE job + self-deregisters + exits → repeat.
- **`runner-entry.sh`** — runs inside the runner container: start inner dockerd,
  reset the inner Docker state left by the previous job, `config.sh --ephemeral`,
  `run.sh` the baked-in agent.
- **`lib.sh`** — shared `config.env` loading.
- **`systemd/gha-dind-pool.service`** — runs the pool on boot. See below.

## Local commands

`local.sh` runs a bounded command directly on this host in a dedicated DinD
container. It uses the same image and container initialization as CI, without
registering a GitHub runner. The existing pool continues independently.

```sh
./local.sh --name oracle-example --workspace /absolute/owned-workspace \
  --output /absolute/new-evidence --timeout-seconds 600 -- \
  bash -c 'go version; node --version; docker info'
```

The workspace is mounted at `/workspace`, and the new evidence directory at
`/evidence`. The inner Docker state uses a separately named volume, removed on
completion. Container names and volumes belonging to another run are never
replaced. Commands, including failures and timeouts, retain their exit status;
complete stdout/stderr is in `container.log`, with lifecycle logs and image
identity alongside it. Evidence ownership is returned to the invoking user.
`--own-workspace` also returns ownership of a caller-owned workspace, including
new build files; use it only for a workspace dedicated to this invocation.
No host Docker socket is mounted.

The existing `gha-dind-net` network and persistent Nix volume must already
exist. Go/npm/Agda caches use the normal cache directories (`CACHE_DIR` can
select another directory). The image must contain `container-init.sh` and
`local-entry.sh`; rebuild with `build-image.sh` before deploying local mode.
Use `IMAGE` to build under a separate tag and `DIND_IMAGE` to select it at run
time. Rebuilding an image does not restart or replace an existing runner.

Local mode exports CI and cache settings and selects the installed Go/Node
toolchains. Set `LOCAL_GO_VERSION` and `LOCAL_NODE_VERSION` to select exact
installed versions; multiple installed versions otherwise fail explicitly.
Credentials are only supplied through an explicit `--env-file`; no GitHub
runner administration token is required or mounted. Docker access still has
the privileged-container trust boundary described below.

This command supplies execution, not a schedule. A host scheduler can prepare
an environment before a test window, then have the already running command
release the actual tests at the specified time. Installing timers or services
is a separate host configuration action.

`bash check.sh` is the maintained verification entrypoint. It retains complete
logs/statuses, requires named contract checks (fake Docker CLI), builds the real
Dockerfile, and checks real container success/failure/timeout, ownership,
cleanup, and default runner initialization with mock registration scripts.
`--contracts` and `--container` select the two CI lanes. No live registration
token is needed. The existing network and Nix volume must already be present.

## Boot-persistent pool

`pool.sh` is the manual bring-up. For a fleet that survives reboot, **systemd is
who starts the runners.** `systemd/gha-dind-pool.service` is the plain-systemd
unit, with install notes in its header.

On NixOS the authoritative install is a NixOS module — add to `/etc/nixos` and
`nixos-rebuild switch`:

```nix
systemd.services.gha-dind-pool = {
  description = "gha-dind ephemeral GitHub Actions runner pool";
  after = [ "docker.service" "network-online.target" ];
  wants = [ "network-online.target" ];
  wantedBy = [ "multi-user.target" ];
  # The pool's host-side commands. A systemd service has a minimal PATH, so name
  # the binaries pool.sh/runner.sh call explicitly. bash MUST be here: the scripts
  # are #!/usr/bin/env bash, and pool.sh spawns runner.sh via its shebang — with
  # no bash on PATH the child fails "bash: not found".
  path = with pkgs; [ bash docker curl jq coreutils hostname ];
  serviceConfig = {
    Type = "simple";
    User = "<user>";                       # must be in the docker group
    WorkingDirectory = "/path/to/gha-dind";
    # Invoke bash explicitly from the store — do NOT rely on the script's
    # #!/usr/bin/env bash shebang: there is no /usr/bin/env for systemd to exec,
    # so a bare ExecStart = ".../pool.sh" fails with status=203/EXEC.
    ExecStart = "${pkgs.bash}/bin/bash /path/to/gha-dind/pool.sh";
    KillSignal = "SIGTERM";
    TimeoutStopSec = 120;
    Restart = "on-failure";
    RestartSec = 10;
  };
};
```

## Host prerequisite — trusted bridge

The DinD container's docker bridge (`br-gha-dind`) **must** be a trusted interface
in the host firewall, or forwarded traffic is filtered and any job that resolves a
public hostname fails with `hostname did not resolve`. This bites integration
tests that talk to the outside world, and it is the single host-side requirement.

On NixOS, add the bridge alongside your existing docker bridges and
`nixos-rebuild switch`:

```nix
networking.firewall.trustedInterfaces = [ "docker0" "br-gha-dind" ];
```

NixOS firewall variants drop forwarded traffic between untrusted docker bridge
endpoints; this is the same coexistence pattern KIND needs on such a host. On
other distributions the equivalent is allowing forwarding for the bridge in your
firewall of choice.

`--privileged` is required for the inner dockerd. It is the same posture KIND's
node containers use, but it *is* a real trust boundary: a job on these runners can
escape to the host. Run them only for repositories whose workflow contents you
trust — do not point this at a repo that accepts `pull_request` runs from forks.

## Non-obvious gotchas (already handled in the scripts)

1. **Trusted bridge** — above. The one host-side requirement.
2. **libicu74 for the runner agent** — the GitHub Actions runner is a glibc .NET
   app; it fails to start without ICU. Its error misleadingly says
   `libstdc++.so.6 => not found` even though libstdc++6 is present — the real dep
   is ICU. Baked into the image.
3. **overlay2 via named volume** — `/var/lib/docker` is a host named volume (a real
   ext4 fs), so the inner dockerd auto-selects overlay2 (fast). No `vfs` needed;
   overlay-on-overlay is what the named volume avoids.
4. **Inter-job Docker reset** — the inner `/var/lib/docker` volume persists across
   a slot's jobs (that is the image cache), so it also carries the *previous* job's
   containers. `runner-entry.sh` removes containers/networks/volumes (keeping
   images) before each job, or a job doing `docker run --name postgres` collides
   with the last one. A hosted runner gets this for free from a fresh VM; here the
   runner must provide it, and it must not live in your workflow.

## Ubuntu base — why

The runner agent is a glibc .NET app and GitHub ships **no musl build**, so an
Ubuntu (glibc) base runs it natively with zero shims. An earlier Alpine attempt
needed a bash symlink, gcompat, and a glibc-`ldd` fix for node's native addons —
all unnecessary on Ubuntu.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).
Contributions are subject to the [Contributor License Agreement](CLA.md).
