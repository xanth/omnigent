# Windows host patch set maintenance

A flat patch set that makes Omnigent run as a native Windows host. Each fix is
its own branch, ready to upstream, and merges onto a release tag tip beside the
others.

The fork is `xanth/omnigent`, remote `xanth`. Placeholders: `<tag>` is the
release tag the set is based on (for example `v0.19.1`), `<fix>` is a fix name.

`<fork-point>` is where the tag's release branch left upstream `main`:
`git merge-base <tag> origin/main`. Fixes start there, not at the tag, because
the release branch adds version and lockfile bumps that `main` does not have.
From the fork point, a pull request to upstream `main` carries only the fix,
and merging the fix onto the tag tip adds only the fix.

## Repo layout

Every consumer uses this layout.

| Path | Content |
|---|---|
| `.` | Root checkout of upstream, remote `origin`. Read-only: any branch, no patch commits |
| `.worktrees/xanth/<branch>` | One worktree per fix branch; the path matches the branch name |
| `.worktrees/patch-maintenance` | The `patch-maintenance` branch |
| `AGENTS.local.md` | The consumer's private notes: machine setup, running from source, schedules. Untracked |

## Branches

| Branch | Base | Content |
|---|---|---|
| `feat/windows-host/<fix>` | `<fork-point>` | One fix as a curated, linear commit series with code and tests |
| `patch-maintenance` | orphan | This file and `Update-PatchSet.ps1`. Never upstreamed; plain append-only history |

`Update-PatchSet.ps1` treats every `feat/windows-host/*` branch as a fix.

## Series

| Fix branch | Problem on native Windows | Upstream status |
|---|---|---|
| `os-env-lazy-tmpdir` | With `sandbox: none`, every `sys_os_*` call fails on `assert self._tmpdir is not None`. The OS-tool helper gets its config through a file in a scratch directory that only an active sandbox creates. | The same hunk and test are in omnigent-ai/omnigent#5852 (open). |
| `pi-cmd-shim` | `shutil.which("pi")` returns npm's `pi.cmd`, and Windows runs it through `cmd.exe`. A newline in `--append-system-prompt` ends the command line, so pi loses `--extension`, `--no-tools` and `--tools` and runs its own tools. | None. |
| `claude-native-relay-port` | `SO_REUSEADDR` lets a second process bind a port another serves, so a second concurrent `claude-native` session's hook reaches the first session's relay, gets 401, and every prompt is blocked. | None. |
| `user-shells` | The "New shell" picker offers only bash; PowerShell 7, Windows PowerShell and cmd are missing. | None. |
| `native-terminals` | Native harnesses and terminals are gated off. With a Windows tmux (RMUX plus its fix set, `xanth/rmux` branch `patch-maintenance`): the pane command's POSIX quoting reaches cmd.exe, panes get a TERM Windows programs do not know, servers that keep no socket file are never stopped, and the AF_UNIX copy bridge and POSIX status relay fail. Series: argv after `--`, `xterm-256color` TERM, kill-server without a socket file, then the gates go with the two POSIX helpers. | None. |

Update this table when you add, change or retire a fix.

## Patch rules

- **Minimal**: change only the lines that fix the problem. Match upstream style
  and its `AGENTS.md`.
- **Isolated**: each fix branch starts at `<fork-point>` and changes no file
  another fix changes. Two fixes that share a file become one fix.
- **Curated history**: a fix branch reads as a patch series for an upstream
  reviewer. Each commit is one reviewable step that builds and passes its
  tests, with subject `fix(windows): <what>`, a body that gives the cause and
  then the change, and a `git commit -s` sign-off (DCO). Use as many commits as
  the explanation needs, and never a stream of work-in-progress changes.
- **Present tense**: the series describes the fix against the current `<tag>`,
  not how the fix developed. On every change and every tag move, drop commits
  that upstream made redundant, reword messages that no longer match upstream,
  and fold corrections into the commit they correct:
  `git commit --fixup=<commit>`, then
  `git -c sequence.editor=: rebase -i --autosquash <fork-point>`.
- **Red first**: the fix's test fails at `<fork-point>` and passes with the fix.

## Update and push

Run `pwsh .worktrees/patch-maintenance/Update-PatchSet.ps1 -Tag <tag>`
after every change to a fix. It rebases, checks and pushes the whole set in one
all-or-nothing run; `Get-Help <script> -Full` describes each step.

When a run fails, every fix is back where it started. Fix the cause by hand,
then run it again:

- **A fix does not rebase**: in its worktree, run the `git rebase --onto`
  command the script prints, resolve the conflicts, and curate the series.
- **A fix has no commits left**: upstream has it. [Retire the fix](#retire-a-fix).
- **Fixes share a file**: combine them into one fix, or change them so each
  touches its own files.
- **A fix does not merge onto the tag**: it conflicts with the release branch's
  own changes. Make the fix apply to both.

## Add a fix

1. Create the branch at the fork point, in its worktree:
   `git worktree add -b feat/windows-host/<fix> .worktrees/xanth/feat/windows-host/<fix> $(git merge-base <tag> origin/main)`
2. Write the test, then confirm it goes red at `<fork-point>`.
3. Make the fix, then confirm the test passes. Run the module's full test file
   and upstream's checks on the changed files, then commit.
4. Add the fix to [Series](#series), then [update and push](#update-and-push)
   with the current `<tag>`.

## Move to a new tag

1. [Update and push](#update-and-push) with `-Tag <new-tag>`, and run it again
   after each fix by hand until it finishes without an error.
2. Curate every fix against the new fork point (see
   [Patch rules](#patch-rules)) and run its tests. If any fix changed, update
   and push again.

## Retire a fix

When upstream makes a fix unnecessary, delete it everywhere:

1. `git worktree remove .worktrees/xanth/feat/windows-host/<fix>`
2. `git branch -D feat/windows-host/<fix>`
3. `git push xanth --delete feat/windows-host/<fix>`
4. Remove its row from [Series](#series).

## Keep this file

This branch is public. This file and the script hold only the shared layout and
patch set maintenance. Machine setup, running from source, and personal
schedules go in the private root `AGENTS.local.md`. No machine names, user
paths or secrets.
