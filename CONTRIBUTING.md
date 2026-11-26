# Contributing

Thank you for helping. This repository is infrastructure code for free cloud tiers; mistakes can cost money or
open access, so changes are reviewed carefully and kept small.

## Ground rules

- **OpenTofu, not Terraform.** Commands are `tofu ...`; CI pins the OpenTofu version in `TOFU_VERSION`.
- **Never put real values in a commit, issue or pull request**: no account, tenancy, project or billing ids, no
  OCIDs, e-mail addresses, domains that are yours, tailnet names or device addresses, keys or tokens, not even
  "harmless" ones. Use placeholders such as `<tenancy-ocid>`, `you@example.com`, `example.com`. A leaked identifier stays in git history.
- **Do not weaken the safety rules** in SECURITY.md: no `pull_request_target`, no credentials for fork pull requests,
  no stored cloud keys where a keyless login exists, bootstrap stacks stay out of CI.
- **Say what you verified.** If you could not run a step against a real account, mark it `verify` in the docs.
- **Docs travel with code.** A change that adds, removes or renames something updates the README, the docs and the
  `.example` files in the same pull request.

## Before you open a pull request

Run the checks listed under "Checks" in the README (formatting, validation, linting, tests, secret scan). The same checks
run in CI on your pull request; pull requests from forks run the checks only, with no credentials and no cloud access.

- Commit messages: a short imperative subject, optionally `type(scope): subject` (for example `fix(infra): ...`).
  Do not add signature or attribution trailers.
- One topic per pull request; explain the reason, not only the change.
- Add or update a test when the code has tests next to it.

## Issues

Use the templates. Remove every identifier and secret from logs before pasting them.
By contributing you agree that your contribution is licensed under the repository's MIT license.
