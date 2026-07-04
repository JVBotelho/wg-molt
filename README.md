# wg-molt

Automatic Mullvad WireGuard key rotation for routers (Asuswrt-Merlin, OpenWrt).

*Molt* — to shed skin, fur, or a shell periodically — is what this tool does to your WireGuard key pair. It's also a fitting name for a Mullvad-adjacent tool: "mullvad" is Swedish for "mole," an animal that molts. `wg-molt` rotates the static WireGuard key pair in a router's Mullvad configuration on a schedule, replicating what the official Mullvad app already does for desktop/mobile clients — but for the "set once and forget" router configs that never get that treatment.

**Not affiliated with Mullvad VPN AB.** This is an independent, community-written tool that talks to Mullvad's public account API. "Mullvad" is used descriptively to say what it's compatible with.

---

## Status

**Early. Not yet usable end-to-end.** This repository is at milestone M1 of a phased build-out:

- Done (M1): repo skeleton, a secret-redacting logger (`src/lib/log.sh`), and an atomic-write journal with lock-based concurrency control (`src/lib/journal.sh`).
- Not yet built: the Mullvad API client, the Asuswrt-Merlin and OpenWrt platform adapters, the `rotate.sh` state machine, and `install.sh`.

There is no rotation logic, no installer, and no router integration yet. If you're looking for something to install today, this isn't it — check back later, or watch the repo for the v1.0 release (Merlin adapter first; OpenWrt follows in v1.1). The full design, including the state machine, failure matrix, and milestone plan, lives in `plano-arquitetura-rotacao-chaves-mullvad.md` (Portuguese).

## Quickstart

Coming soon. Installation instructions will be added once `install.sh` and the Merlin adapter exist and have been validated on real hardware — there's no point documenting steps for a tool that doesn't run yet.

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

## Sources

- Original research: <https://tmctmt.com/posts/mullvad-exit-ips-as-a-fingerprinting-vector/> (published 2026-05-14; mitigation update 2026-05-29)
- Coverage: <https://korben.info/en/mullvad-wireguard-key-fingerprinting-vpn.html>
- Mullvad's blog post on the incident (2026-05-20, "log out and back in" recommendation): <https://mullvad.net/en/blog/exit-ip-fingerprinting-between-vpn-servers>
- Mitigation rollout status page: <https://mullvad.net/help/exit-ip-vpn-servers-mitigation-rollout>

## License

MIT. See `LICENSE`.
