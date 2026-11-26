# Security policy

## Reporting a vulnerability

Please do **not** open a public issue for a security problem. Use GitHub's private reporting:
the **Security** tab of this repository, then **Report a vulnerability**. Describe what you found and how to
reproduce it. Never include real credentials, account or tenancy identifiers, e-mail addresses or tokens: a
description and a redacted log are enough.

Only the `main` branch is supported. This is infrastructure code that you run against your own cloud accounts:
you are responsible for what you deploy and for the bills of your accounts (read "Spending caps" in the README).

## If you find a secret or an identifier in this repository

Report it privately in the same way. Rotate the credential first if it is yours.

## How this repository protects you, and what you must do

1. **Deploy from a private repository.** Do not fork this repository to deploy it (a fork of a public
   repository is public). Clone it, then push it to a **new private repository** of your own
   (`git remote rename origin upstream`, then `gh repo create <you>/<name> --private --source . --push`, or GitHub's
   "Use this template" with visibility Private). Reasons: the saved plan files uploaded as workflow artifacts
   contain values that are secret (tokens, keys), CI holds credentials for your cloud accounts (the OpenTofu state
   key, or the Cloudflare API token and R2 keys), and a public repository lets strangers read run logs and artifacts.
2. **No credentials in the code.** Examples use placeholders (`<tenancy-ocid>`, `you@example.com`, `example.com`).
   `*.tfvars` files are git-ignored; secrets go into GitHub Actions secrets or into your cloud's secret store.
   A gitleaks scan runs on every pull request and every push (pinned, checksum-verified binary).
3. **Pull requests from forks can never reach a cloud login.**
   - No workflow uses `pull_request_target` or `workflow_run`, so no workflow runs fork code with the base repository's secrets.
   - The only job that holds cloud credentials (`plan` in `tofu.yml`, where the repository has one) is skipped for pull requests whose head
     repository is not this repository (`github.event.pull_request.head.repo.full_name == github.repository`).
   - The apply job runs only for `workflow_dispatch` (a person with write access clicks it) on `refs/heads/main`, and the cloud
     trust rules (Oracle identity propagation trust, Google Workload Identity pool) accept only tokens of your repository and, for apply, only
     that event and ref. By design the trust cannot tell a same-repository pull request from a fork pull request, because the token does
     not carry the head repository: the protection against forks is that GitHub does not give fork pull requests a write
     token, secrets or an OIDC token, plus the job guard above. Do not weaken either (**verify** current GitHub behaviour in
     its documentation for your plan).
   - Set the repository's **Settings -> Actions -> General -> Fork pull request workflows** to require approval for all outside collaborators,
     keep the default workflow token read-only, and leave "Send write tokens to workflows from fork pull requests" and
     "Send secrets and variables to workflows from fork pull requests" **off**.
4. **Bootstrap stacks are laptop-only.** The stack that holds IAM, quotas, budgets and buckets is applied by you, never by CI,
   so a compromised pipeline cannot widen its own rights or delete the state bucket.
5. **Pinned actions.** GitHub Actions are pinned to commit SHAs and updated by Renovate. Tool versions that workflows download
   (OpenTofu, trivy, tflint, gitleaks with its sha256, the OCI CLI, Helm charts where a workflow installs one) are pinned in
   `env:` blocks at the top of the workflow.
6. **State holds secrets.** The OpenTofu state of a stack can contain keys and tokens that the provider returns. Its bucket must
   stay private and versioned (the code creates it that way); never copy a state file into a repository, an issue or a chat.
   Saved plans (workflow artifact `tfplan-<sha>`, kept 7 days) and pull-request plan comments can show sensitive values too:
   this is the main reason to deploy from a private repository.
7. **Repository settings to make once** (the README's "Use it" has the commands): Actions default token read-only; fork pull
   requests need approval; Actions may not approve pull requests; secret scanning and push protection on (a private repository may need
   GitHub's paid secret-protection plan: the gitleaks workflow scans every push either way); **protect `main`** (pull request and one
   review, applied to administrators too). Branch protection and required reviewers on a **private** repository need GitHub Pro, Team
   or Enterprise. On the Free plan they do not exist: then keep the repository single-owner and give write access to nobody, because a
   person with write access can edit a workflow on a branch and run it with whatever credentials a pull request job holds.
8. **Least privilege, stated.** Pull-request jobs get the read-only identity where the cloud offers keyless login (Oracle, Google);
   where it does not (Cloudflare API token, R2 keys) the README says to create a separate read-only token for the plan job.
   Apply identities are bound to your repository, to `refs/heads/main` and (Google) to manual runs. Spending caps (quotas, budgets,
   the Google billing kill switch) are on by default: do not turn them off to get a plan through.

## What this project does not protect against

A repository owner or collaborator with write access can run anything the pipeline can. Keep the deployed repository
single-owner or review every change. Tool and provider vulnerabilities (OpenTofu, providers, container images that
float on `:latest`) are outside this repository: keep them updated.
