# Contributing

Shello is built by two developers, Michele ([@migilabs](https://github.com/migilabs)) and Florian ([@violinwav](https://github.com/violinwav)), each working with Claude Code. These rules keep two people and two Claudes from working against each other. `CLAUDE.md` imports this file, so both Claudes follow it too.

Outside contributions are not accepted yet: they need the contributor licence agreement from [ADR 0001](docs/adr/0001-gplv3-licence.md) first.

## Where things are decided

| Question | Source of truth |
| --- | --- |
| What Shello does | `README.md` (functional specification) |
| How Shello is built | `docs/spec/STACK.md` |
| What it looks like | `docs/ui/` |
| What words mean | `GLOSSARY.md` |
| Why a hard-to-reverse decision was made | `docs/adr/` |
| What is being worked on, and by whom | GitHub Issues |

When two of these disagree, do not silently pick one. Say so in the issue or pull request and let both developers decide. `docs/spec/STACK.md` section 15 lists the known disagreements.

## Picking up work

- Work from an issue. The triage labels are explained in `docs/agents/triage-labels.md`: `ready-for-agent` issues can be handed to Claude, `ready-for-human` issues need a person (often a physical device).
- Claim an issue before starting it: assign it to yourself. Never start an issue assigned to the other developer; ask first.
- One issue, one branch, one pull request. The pull request says `Closes #<issue>`.

## Building and testing

First build libssh and OpenSSL from verified source with `Vendor/build.sh` (needs `brew install cmake gnupg`). The output is not in git. Rerun the script after `Vendor/` changes; it does nothing when the libraries are current. See `Vendor/README.md`.

Open `Shello.xcodeproj` in Xcode 26.6 and use the `Shello` scheme: it runs the app and, with Product → Test, every `ShelloKit` unit test plus the UI tests. The first build asks you to trust SwiftTerm's build plugin, which writes its version information and its terminfo table into SwiftTerm's sources; SwiftTerm is pinned exactly, so the plugin only changes with the pin. From the command line, the same checks CI runs (`.github/workflows/ci.yml`), where `-skipPackagePluginValidation` stands in for that prompt:

```sh
xcrun swift-format lint --strict --recursive --parallel App AppTests UITests Packages/ShelloKit
xcodebuild test -project Shello.xcodeproj -scheme Shello -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -skipPackagePluginValidation
```

Build settings live in `Configurations/*.xcconfig`, not in the Xcode project. Set them there so both developers see the change in review.

## Branches and pull requests

- **Early MVP exception (from Oct 20, 2026):** the MVP slices (#19 and its sub-issues, plus spike tickets #8–#10) land directly on the `dev` branch without review, one commit per issue. Each commit passes the same checks as CI before it is pushed, and CI also runs on every push to `dev`. `dev` reaches `main` through one pull request, reviewed as a whole. The rules below still apply to everything else.
- Nothing is pushed to `main` directly, documents included. Every change goes through a pull request.
- The other developer is asked for a review automatically (`.github/CODEOWNERS`). Approval is not required: the author may merge their own pull request.
- Pull requests are squash-merged, so the pull request title becomes the commit on `main`. Write it as one.
- Keep branches short-lived. To catch up, merge `main` into your branch. Never force-push a branch the other developer may have pulled.
- The pull request template follows the `pr` skill: Summary, Evidence, Merge Danger.

## Working with Claude Code

- `CLAUDE.md`, `CONTRIBUTING.md`, `.claude/settings.json`, `.claude/hooks/` and `.claude/skills/` are shared. Change them only through a pull request, because they change how both Claudes behave.
- Personal instructions go in `CLAUDE.local.md` or `~/.claude/CLAUDE.md`, personal permissions in `.claude/settings.local.json`. All three stay out of git.
- `.claude/settings.json` stops both Claudes from force-pushing and from pushing to `main`.
- New domain terms go into `GLOSSARY.md`, hard-to-reverse decisions into `docs/adr/`. The `domain-modeling` skill does both.
- `@claude` in an issue or pull request comment runs Claude in GitHub Actions for either developer. It runs on the `CLAUDE_CODE_OAUTH_TOKEN` repository secret, so it uses the Claude subscription of whoever created that token.

## Repository settings

Only a repository admin (Florian) can change these:

- **Branch protection:** Settings → Rules → Rulesets → New ruleset → Import a ruleset, and choose `.github/rulesets/protect-main.json`. It requires a pull request for `main` (no approval), blocks force pushes and deleting `main`, and allows squash merges only. Admins are not exempt.
- **Merge button:** Settings → General → Pull Requests: allow only squash merging, with "Default to pull request title and description", and turn on "Automatically delete head branches".
