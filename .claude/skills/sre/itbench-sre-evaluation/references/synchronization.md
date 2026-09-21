# Local and Remote Synchronization

## Scope and Authority

This procedure synchronizes code and configuration, not experiment data. The shared Git remote is the authority for code history:

```text
local Git worktree:  /Users/Edison/ITBench
remote Git worktree: /data/edison/piagent-itbench-eval/ITBench
Git remote:          https://github.com/pengben945/ITBench.git
remote host:         10.106.3.100
SSH user:            root
SSH identity file:   ~/.ssh/id_ed25519
```

The remote runtime workspace is outside that Git worktree:

```text
/data/edison/piagent-itbench-eval/evaluation/
/data/edison/piagent-itbench-eval/datasets/
/data/edison/piagent-itbench-eval/runs/
```

Do not treat runtime data as a second code branch. Do not put Ground Truth, raw data, Agent Cases, historical runs, API credentials, or model caches into a code commit.

## Standard Bidirectional Flow

Before editing on either endpoint:

```bash
git status --short
git fetch origin
git pull --ff-only origin main
```

If the worktree is dirty, inspect and preserve the changes before pulling. Do not use `git reset --hard` or discard changes. After editing:

```bash
git diff --check
git status --short
git add <intended-code-files>
git diff --cached --check
git commit -m "<focused change>"
git push origin main
```

On the other endpoint, update only after the push succeeds:

```bash
git fetch origin
git pull --ff-only origin main
git rev-parse HEAD
git status --short
```

The final check must show the same `HEAD` commit on both code worktrees and no uncommitted code changes. Run tests or the V6 `--check-only` preflight after updating the remote runtime files.

## Local-to-Remote Example

```bash
cd /Users/Edison/ITBench
git status --short
git add .claude/skills/skill-rules.json .claude/skills/sre/itbench-sre-evaluation evaluation/README.md evaluation/prompts evaluation/schemas evaluation/run-configs evaluation/scoring evaluation/scripts evaluation/deployment AGENTS.md .gitignore
git diff --cached --check
git commit -m "feat: update ITBench evaluation workflow"
git push origin main

ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes root@10.106.3.100 \
  'cd /data/edison/piagent-itbench-eval/ITBench && git fetch origin && git pull --ff-only origin main && git rev-parse HEAD'
```

Do not blindly stage `datasets/`, `runs/`, `outputs/`, reports, `.idea/`, or cache directories. Check `.gitignore` and `git status` before staging.

## Remote-to-Local Example

When the change was made on the server:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes root@10.106.3.100 \
  'cd /data/edison/piagent-itbench-eval/ITBench && git status --short && git diff --check && git add <intended-code-files> && git commit -m "<focused change>" && git push origin main'

cd /Users/Edison/ITBench
git fetch origin
git pull --ff-only origin main
git rev-parse HEAD
git status --short
```

The remote shell command must be reviewed for the exact intended paths before execution. Do not commit run artifacts or Ground Truth simply because they exist beside the code.

## Deploying Runtime Files After Git Sync

If the runner uses the outer remote `evaluation/` directory, compare the committed code with that runtime directory first:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes root@10.106.3.100 \
  'cd /data/edison/piagent-itbench-eval && rsync -an --itemize-changes --exclude="ground_truth/" --exclude="reports/" --exclude="__pycache__/" ITBench/evaluation/ evaluation/'
```

Review the dry-run. Only then use the same command with `-a` instead of `-an`. Preserve `evaluation/ground_truth/`, `evaluation/reports/`, `datasets/`, and `runs/`; never add `--delete` for this workflow. Deploy the Skill separately if the remote Agent starts from the outer workspace:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes root@10.106.3.100 \
  'cd /data/edison/piagent-itbench-eval && mkdir -p .claude/skills && rsync -an --itemize-changes ITBench/.claude/skills/ .claude/skills/'
```

After reviewed deployment, run the V6 `--check-only` command from the outer workspace and record the resulting commit, model, prompt/schema versions, and run ID.

## Divergence and Safety Rules

- If `git fetch` shows both local and remote commits advanced, stop; do not force-push or silently rebase. Report the two commit IDs and resolve deliberately.
- If either worktree has uncommitted changes, do not overwrite them with `pull`, `rsync`, or cleanup commands.
- If the remote path, branch, or Git remote differs from this reference, verify it read-only and report the mismatch before changing anything.
- SSH commands must use `-i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes`; never print private-key contents, auth files, API keys, proxy credentials, or subscription URLs.
- Before any broad synchronization, show the source path, destination path, exclusions, dry-run output, and expected impact. Use explicit paths and preserve rollback through Git history.
