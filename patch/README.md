# OS patching of the Oracle micros (micro-edge, micro-kuma)

Short version. The design, the other machines and the secrets (names only) are in <home-server-repo> `ops/patch/README.md`.
The Oracle cluster nodes are **not** patched in place: see `docs/NODE-IMAGE.md`.

- **What:** `unattended-upgrades` installs security updates every day (Ubuntu 24.04 defaults, `Automatic-Reboot "false"`). `patch-agent` reports to ntfy.sh (and, for micro-kuma, the Home Kuma heartbeat), reminds you every 3 days while a reboot waits (first alert as soon as one is needed) (mode `alert`, your pick), and after every boot checks Docker, Tailscale and the containers (micro-edge: `edge_tailscale edge_adguard edge_ghcr_cache`; micro-kuma: the Kuma stack and `kuma_push`). An ntfy alert names the machine when something is missing.
- **Night:** Friday 00:00 UTC (04:00 local time), used only in mode `staggered` (`patch_reboot_mode` in `infra/variables.tf`, read at creation). Both micros share Friday; micro-edge runs no Kuma, so the 2-of-3 alert rule keeps two voters (Home Monday, Google VM Wednesday).
- **New machine:** cloud-init (`infra/micro-cloud-init.yaml`) installs it on the first boot. The agent files are gzip'd in `user_data` (26 KB of Oracle's 32,000 bytes; a precondition in `infra/micros.tf` fails the plan above 30,000).
- **Machine that already exists** (cloud-init does not run again): copy and run the same script, commands in `docs/WHAT-YOU-DO.md` (section 17):
  `scp` the two files, then `sudo bash apply-patching.sh --host <micro-edge|micro-kuma> --day fri --kuma <no|yes> --containers '...' --ts-container <...>`.
- **Files here:** `patch-agent`, `apply-patching.sh` (identical copies of <home-server-repo> `ops/patch/`; `sha256sum` must match), `test_patch_agent.py` (`cd patch && python3 -m unittest test_patch_agent`, CI job `patch-tests`).
- **Untested on the real micros:** the units under real systemd, the real Ubuntu 24.04 log format, the `gz+b64` cloud-init encoding, the reboot-to-back time of a 1 GB micro.
