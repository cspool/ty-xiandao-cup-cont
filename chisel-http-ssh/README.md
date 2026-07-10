# Chisel HTTP SSH Scripts

These scripts configure local VS Code Remote-SSH access to a remote container
when the platform only exposes an HTTP service port.

## Scripts

```text
remote_config_chisel.sh  Run inside the container once to install chisel/sshd and add the local public key.
remote_start_chisel.sh   Run inside the container to start sshd and chisel server.
local_config_chisel.sh   Run locally once to install chisel and write SSH config.
local_start_chisel.sh    Run locally to start the chisel client tunnel.
local_mount_remote_home.sh
                          Mount /public/home/tangyu408 to ./remote-home with sshfs.
local_umount_remote_home.sh
                          Unmount ./remote-home.
local_remote_exec.sh      Local helper that forwards shell commands to the remote container over SSH.
local_codex_ssh.sh        Run local Codex on the sshfs mount and inject remote-command instructions.
```

## Unified Config

The setup, start, mount, unmount, and Codex launcher scripts automatically read
`config.env` from the same directory as the script. Copy the template and fill
the private values:

```bash
cd /workspace/scnet_ssh_tracing/chisel-http-ssh
cp config.env.example config.env
chmod 600 config.env
```

Fill at least:

```bash
CHISEL_AUTH_USER="your-user"
CHISEL_AUTH_PASS="your-password"
PLATFORM_URL="https://SCNET_PLATFORM_FORWARD_URL/"
LOCAL_PUBKEY="ssh-ed25519 AAAA..."
```

Use the same `config.env` values in the local script directory and the remote
script directory. `PLATFORM_URL` is only needed locally; `LOCAL_PUBKEY` is only
needed by `remote_config_chisel.sh`.

Any command-line option still overrides the config value. You can also point a
script at another config file with `--config PATH` or:

```bash
CHISEL_HTTP_SSH_CONFIG=/path/to/config.env bash local_start_chisel.sh
```

Do not commit or share `config.env`; it contains credentials. The file is
ignored by `.gitignore`.

## Quick Start

Local:

```bash
cd /workspace/scnet_ssh_tracing/chisel-http-ssh
bash local_config_chisel.sh --generate-key
cat ~/.ssh/id_ed25519.pub
```

Paste the printed public key into `LOCAL_PUBKEY` in the remote copy of
`config.env`.

Remote container e-shell:

```bash
cd /public/home/tangyu408/chisel-http-ssh

bash remote_config_chisel.sh

bash remote_start_chisel.sh --detach
```

`remote_start_chisel.sh` kills existing `chisel` processes by default before it
starts the server, so rerunning the same command refreshes the chisel server and
auth. If you explicitly want to reuse an existing server and fail when port
`8080` is occupied, add `--no-restart-chisel`:

```bash
bash remote_start_chisel.sh --detach --no-restart-chisel
```

Local:

```bash
cd /workspace/scnet_ssh_tracing/chisel-http-ssh
bash local_start_chisel.sh
```

Test:

```bash
ssh worker-0-chisel
```

or bypass local SSH config:

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 root@127.0.0.1 -p 2222
```

Use the same auth values on remote and local. Do not commit or share real
passwords or platform URLs containing private tokens.

## Mount Remote Home With sshfs

Keep `local_start_chisel.sh` running in one local terminal, then run from the
directory where you want the mount point:

```bash
cd /workspace/scnet_ssh_tracing
bash chisel-http-ssh/local_mount_remote_home.sh
ls -la remote-home
```

Unmount:

```bash
cd /workspace/scnet_ssh_tracing
bash chisel-http-ssh/local_umount_remote_home.sh
```

This mount is for local editor/file browsing. If you run `codex -C remote-home`
directly, Codex commands still run on the local machine. Use the local Codex
SSH workflow below when project commands must execute in the remote container.

## Run Local Codex With Remote Container Commands

This is the intended Codex setup for this environment:

- Codex CLI runs locally and talks to OpenAI from the local machine.
- The remote home is visible locally through sshfs.
- The remote container does not need Codex installed.
- Project shell commands are forwarded to the remote container through SSH.

Start local Codex:

```bash
cd /workspace/scnet_ssh_tracing
bash chisel-http-ssh/local_codex_ssh.sh
```

The launcher will:

- verify `ssh worker-0-chisel` reaches the container,
- mount `/public/home/tangyu408` to `./remote-home` if needed,
- install `remote-home/.codex/remote_exec`,
- start local `codex -C ./remote-home`,
- inject instructions telling Codex to run project commands through
  `remote-home/.codex/remote_exec`.

Pass Codex options after `--`:

```bash
cd /workspace/scnet_ssh_tracing
bash chisel-http-ssh/local_codex_ssh.sh -- --model gpt-5.5
```

Manual command forwarding test:

```bash
cd remote-home
./.codex/remote_exec --print-cwd
./.codex/remote_exec --shell 'pwd && hostname && python -V'
```

Inside Codex, project commands should use:

```bash
./.codex/remote_exec --shell 'pytest -q'
./.codex/remote_exec -- python train.py --help
```

If Codex cannot open the SSH connection because its local sandbox blocks
network access, rerun with:

```bash
bash chisel-http-ssh/local_codex_ssh.sh --full-access
```

Use `--full-access` only when needed. It gives local Codex broader access on the
local machine; the safer default is `workspace-write` with command network
access enabled for the SSH tunnel.
