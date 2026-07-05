# wg-molt

Automatic Mullvad WireGuard key rotation for routers (Asuswrt-Merlin, OpenWrt).

*Molt* — to shed skin, fur, or a shell periodically — is what this tool does to your WireGuard key pair. It's also a fitting name for a Mullvad-adjacent tool: "mullvad" is Swedish for "mole," an animal that molts. `wg-molt` rotates the static WireGuard key pair in a router's Mullvad configuration on a schedule, replicating what the official Mullvad app already does for desktop/mobile clients — but for the "set once and forget" router configs that never get that treatment.

**Not affiliated with Mullvad VPN AB.** This is an independent, community-written tool that talks to Mullvad's public account API. "Mullvad" is used descriptively to say what it's compatible with.

---

## Status

**Stable (v1.0.0).** 
The core orchestration, API integrations, Asuswrt-Merlin platform support, state machine (`rotate.sh`), and installers are fully implemented and validated on real Asuswrt-Merlin hardware in production environments. The logic strictly enforces forward-recovery using a robust journaling mechanism. 

OpenWrt support is slated for v1.1.

## Quickstart

**Prerequisites (Asuswrt-Merlin only):**
You must enable custom scripts in the WebUI:
`Administration -> System -> Enable JFFS custom scripts and configs` (Set to **Yes**).

### Install

To install `wg-molt`, you must first transfer the script files to the router. The easiest way is to download the release tarball and extract it, or use `scp` to send the unzipped files.

**Note:** The legacy `scp` protocol (especially when using the `-O` flag, which is required for Dropbear SSH on Asuswrt) cannot create new remote directories automatically. You must create the temporary directory on the router first.

**From your PC terminal:**
```sh
# Copy the files to the router (assuming you are in the wg-molt folder)
# We copy them to the temporary RAM disk (/tmp) first
scp -O -r ./src ./install.sh ./uninstall.sh admin@192.168.50.1:/tmp/
```

**Then, SSH into the router and run the installer:**
```sh
cd /tmp
sh ./install.sh
```

The installer will prompt you for your 16-digit Mullvad account number and your WireGuard interface (default `wgc1`). It will install the tool to `/jffs/addons/wg-molt`, generate a randomized cron job (jittered between 03:00 and 05:59 AM) to rotate the key every 7 days, and safely register a boot-time hook in `/jffs/scripts/services-start`.

### Test the integration (Dry Run)

You can verify that the installation succeeded and the tool can communicate with Mullvad's API without modifying any keys:

```sh
/jffs/addons/wg-molt/rotate.sh --dry-run
```
This safely performs Preflight, Auth, and Keygen, but stops right before replacing your keys on the router or the API.

### Configuration

By default, the script rotates the key every 7 days. The cron job runs every night, but the script checks the age of your current key and logs why it's skipping if it is younger than the configured threshold. This ensures rotations aren't skipped if the router is turned off on the scheduled day.

If you want to change the rotation interval (e.g., to rotate daily), edit the configuration file:

```sh
sed -i 's/ROTATE_DAYS=7/ROTATE_DAYS=1/' /jffs/addons/wg-molt/config
```

### Forcing a rotation

To rotate immediately regardless of how recently the key was last rotated (useful for manual testing), pass `--force`:

```sh
/jffs/addons/wg-molt/rotate.sh --force
```

### Uninstall

```sh
sh ./uninstall.sh
```
The uninstaller safely removes the cron job, boot hooks, and directories. If a key rotation was interrupted mid-flight (leaving an active journal), the uninstaller will block removal to prevent data loss. You can resolve this by running `/jffs/addons/wg-molt/rotate.sh --reconcile-only` or use `--force` to bypass the safeguard.

## Target platforms

- **Asuswrt-Merlin** (primary target, v1.0)
- **OpenWrt** (secondary target, v1.1)

Implementation is pure POSIX `sh`, written to run under busybox `ash` — no bashisms, no arrays, no `[[`, no process substitution. The only runtime dependencies are what's already on these firmwares: `wg`, `curl`, and busybox itself. `jq` is used opportunistically if present (e.g. via Entware), never required.

## Why this exists

### Today: a known, partially-mitigated vulnerability

Researcher tmctmt published research on 2026-05-14 showing that Mullvad's exit-IP assignment is derived deterministically from a client's WireGuard public key. Across 3,650 tested pubkeys, only 284 distinct IP combinations appeared, out of a theoretical space of ~8.2 trillion — because the same derived float places a user at the same percentile of the IP pool on *every* server. In practice, someone holding IP logs from two accounts can correlate them with >99% confidence by comparing that float range, even across different exit countries, without any cooperation from Mullvad.

Mullvad acknowledged the issue and began a server-side mitigation rollout on 2026-05-29. **As of 2026-07-03, the public rollout-status page showed only 54% of servers mitigated (295 of 539)** — see the [rollout status page](https://mullvad.net/help/exit-ip-vpn-servers-mitigation-rollout) for the current figure, since this number will go stale. Note also that IP selection remains deterministic by pubkey even on mitigated servers.

### Forever: a static key is a long-term identifier regardless of server-side fixes

Even with full mitigation, a WireGuard public key that never changes is still a durable correlation handle across time. The official Mullvad app already treats this as worth defending against — it rotates its key every 720 hours by default. Router configs, set up once via the official WireGuard guide, typically never rotate at all: the pubkey and internal tunnel address stay frozen indefinitely.

Mullvad's own advice in response to the incident was to log out and back in in the app to get a fresh key. That advice has no equivalent for a static router configuration — there's no "log out" button on a `wgc1` interface in nvram.

Mullvad's advice is to log out and back in to rotate your key. Your router doesn't have that button. This is that button.

### What this is not

This tool does not "fix" the correlation vulnerability, and it should never be described that way. Server-side mitigation is Mullvad's work, not this tool's, and roughly half the fleet is still unmitigated as of the date above. What `wg-molt` provides is key hygiene parity with the official app for the router use case — reducing the window a static key stays valid as a correlation target, nothing more. Overstating this would cost the one thing a security-adjacent tool actually needs: credibility.

## Security

- Account numbers and private keys are never logged and are read strictly from protected `chmod 600` files or standard input to avoid leaking secrets to process lists (`ps`).
- **Known Platform Limitation (Asuswrt-Merlin):** Final persistence to flash memory uses the native `nvram` utility (`nvram set var=key`). Because Asuswrt's `nvram` binary does not support reading values from a file or `stdin`, the private key is inherently exposed via command-line arguments (`argv`) for a fraction of a second during the save operation. This is a documented, accepted risk since there is no alternative, and the risk is entirely local (restricted to other processes with root access on the router).

## Sources

- Original research: <https://tmctmt.com/posts/mullvad-exit-ips-as-a-fingerprinting-vector/> (published 2026-05-14; mitigation update 2026-05-29)
- Coverage: <https://korben.info/en/mullvad-wireguard-key-fingerprinting-vpn.html>
- Mullvad's blog post on the incident (2026-05-20, "log out and back in" recommendation): <https://mullvad.net/en/blog/exit-ip-fingerprinting-between-vpn-servers>
- Mitigation rollout status page: <https://mullvad.net/help/exit-ip-vpn-servers-mitigation-rollout>

## License

MIT. See `LICENSE`.
