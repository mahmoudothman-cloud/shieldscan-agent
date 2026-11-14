# shieldscan-agent

The ShieldScan on-prem agent: one static binary that runs **inside your network**, pulls scan jobs from your ShieldScan workspace over **outbound HTTPS only**, runs the scanners locally against targets the internet cannot reach (`10.0.0.5`, `erp.corp:8080`, a service on `127.0.0.1`), and posts the results back. It opens no inbound ports, needs no VPN, and never receives a job for a project that is not bound to it.

This repository holds **binaries and release notes only**. The source is part of the ShieldScan engine.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/mahmoudothman-cloud/shieldscan-agent/main/install.sh | sh
```

The script downloads the archive for your OS/architecture (Linux and macOS, amd64 and arm64), checks its SHA-256 against the release's `checksums.txt`, verifies the Sigstore signature on `checksums.txt` when `cosign` is installed, and puts `shieldscan-agent` in `/usr/local/bin`. Pin a version with `sh -s -- v0.1.0`. Or download the archive from [Releases](https://github.com/mahmoudothman-cloud/shieldscan-agent/releases) and verify by hand:

```sh
sha256sum -c --ignore-missing checksums.txt
cosign verify-blob --certificate checksums.txt.pem --signature checksums.txt.sig \
  --certificate-identity-regexp 'github.com/mahmoudothman-cloud/shieldscan-engine' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com checksums.txt
```

## Scanners

The agent drives seven open-source scanners it expects to find on `PATH` (or under `SHIELDSCAN_TOOLS_DIR`). `shieldscan-agent doctor` tells you which are missing before a scan does; a missing tool is reported in the dashboard, and only jobs for that tool fail.

| tool | what it does on-prem | Ubuntu / Debian | macOS (Homebrew) |
|---|---|---|---|
| [nuclei](https://github.com/projectdiscovery/nuclei) | template-based vulnerability checks | `go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest && nuclei -update-templates` | `brew install nuclei && nuclei -update-templates` |
| [httpx](https://github.com/projectdiscovery/httpx) | live-host probing (recon) | `go install github.com/projectdiscovery/httpx/cmd/httpx@latest` | `brew install httpx` |
| [subfinder](https://github.com/projectdiscovery/subfinder) | subdomain enumeration (recon) | `go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest` | `brew install subfinder` |
| [nmap](https://nmap.org) | port and service discovery | `sudo apt install nmap` | `brew install nmap` |
| [sslyze](https://github.com/nabla-c0d3/sslyze) | TLS configuration | `pipx install sslyze` | `pipx install sslyze` |
| [nikto](https://github.com/sullo/nikto) | web server misconfiguration | `git clone https://github.com/sullo/nikto ~/.local/nikto && export SHIELDSCAN_NIKTO_BINARY=~/.local/nikto/program/nikto.pl` | `brew install nikto` |
| [wapiti](https://github.com/wapiti-scanner/wapiti) | web application scanner | `pipx install wapiti3` | `pipx install wapiti3` |

Nuclei templates live in `~/nuclei-templates` by default (`SHIELDSCAN_NUCLEI_TEMPLATES` to change). Each tool can also be pointed at explicitly with `SHIELDSCAN_<TOOL>_BINARY`.

## Enrol

1. In ShieldScan, **Settings → Agents → New agent**. You get a one-time enrolment token, valid 24 hours, shown once.
2. On the machine that will run the agent:

   ```sh
   shieldscan-agent enroll --api https://<your ShieldScan URL> --token ss_enrol_…
   ```

   The token is exchanged for a long-lived agent key, saved to `agent.json` (mode 0600) in the state directory — `/var/lib/shieldscan-agent` when it exists and is writable, else `~/.shieldscan-agent`, or `SHIELDSCAN_AGENT_STATE_DIR`. The key is never printed.
3. Bind a project to the agent on the project's settings page. A bound project needs no DNS or meta-tag domain verification — the enrolment is the authorisation — and its scans run only on that agent.

## Run

Foreground:

```sh
shieldscan-agent run
```

As a service (Linux, systemd), using the unit shipped in every archive:

```sh
sudo install -m 0644 shieldscan-agent.service /etc/systemd/system/
sudo useradd --system --home /var/lib/shieldscan-agent --shell /usr/sbin/nologin shieldscan-agent
sudo mkdir -p /var/lib/shieldscan-agent && sudo chown shieldscan-agent: /var/lib/shieldscan-agent
sudo -u shieldscan-agent SHIELDSCAN_AGENT_STATE_DIR=/var/lib/shieldscan-agent \
  shieldscan-agent enroll --api https://<your ShieldScan URL> --token ss_enrol_…
sudo systemctl enable --now shieldscan-agent
journalctl -u shieldscan-agent -f
```

Make sure the scanners are on the service's `PATH` (set `SHIELDSCAN_TOOLS_DIR` in the unit's `Environment=` lines if they live somewhere else).

The agent heartbeats every 30 seconds with its version and the health of each tool; the Agents page shows it as **online**, and as **offline** after 90 seconds without a heartbeat (new scans on its projects are then refused with `agent_offline` rather than queued into the void). Jobs are processed one at a time. Progress streams to the dashboard live, as for a cloud scan.

## Commands

| command | |
|---|---|
| `enroll --api <url> --token <t>` | exchange the one-time token for an agent key |
| `run` | heartbeat and process jobs until stopped |
| `doctor [--api <url>]` | list tools (found / missing / version) and whether the API is reachable; exit 1 if anything is wrong |
| `version` | print the version |

Exit codes of `run`: `0` clean stop, `1` not enrolled or state error, `3` **revoked** — the key was revoked in the dashboard; the local state file is removed and systemd does not restart on this code.

## Environment

| variable | default | |
|---|---|---|
| `SHIELDSCAN_AGENT_STATE_DIR` | `/var/lib/shieldscan-agent` or `~/.shieldscan-agent` | where `agent.json` lives |
| `SHIELDSCAN_TOOLS_DIR` | — | searched before `PATH` for the scanners |
| `SHIELDSCAN_<TOOL>_BINARY` | — | explicit path for one tool (`NUCLEI`, `NMAP`, `HTTPX`, `SUBFINDER`, `SSLYZE`, `NIKTO`, `WAPITI`) |
| `SHIELDSCAN_NUCLEI_TEMPLATES` | `~/nuclei-templates` | nuclei templates directory |
| `SHIELDSCAN_NIKTO_TLS_CAPABLE` | `0` | set `1` when your nikto has the SSL modules |
| `SHIELDSCAN_LOG_LEVEL` | `info` | `trace` … `error` |

## What the agent sends, and what it does not

Outbound only, to your ShieldScan URL: a heartbeat (version, hostname, OS/arch, per-tool status), long-polls for jobs, scan progress events, and the findings of each job. It never opens a listening socket, never reaches any other host on the internet, and holds no database or cloud credentials — only its own agent key, which an administrator can revoke at any time.

## Security

Please report security issues privately to the ShieldScan team rather than in a public issue.

## Licence

See [LICENSE](LICENSE). The scanners the agent invokes are separate programs under their own licences.
