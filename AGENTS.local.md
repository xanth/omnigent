# Windows host patch set maintenance

A flat patch set that makes Omnigent run as a native Windows host. Each fix is
its own branch, ready to upstream. A composite branch octopus-merges every fix
onto a release tag tip.

The fork is `xanth/omnigent`, remote `xanth`. Placeholders: `<tag>` is the
release tag the set is based on (for example `v0.19.1`), `<fix>` is a fix name.

## Repo layout

Every consumer uses this layout.

| Path | Content |
|---|---|
| `.` | Root checkout of upstream, remote `origin`. Read-only: any branch, no patch commits |
| `.worktrees/xanth/<branch>` | One worktree per patch branch; the path matches the branch name |
| `AGENTS.local.md` | The consumer's private notes: machine setup, running from source, schedules. Untracked |

## Branches

| Branch | Base | Content |
|---|---|---|
| `feat/windows-host/<fix>` | `<tag>` tip | One fix as a curated, linear commit series with code and tests |
| `feat/windows-host/main` | `<tag>` tip | One octopus merge of every fix branch, with the `<tag>` tip as first parent |
| `feat/windows-host/patch-maintenance` | orphan | This file and `Build-PatchSet.ps1`. Never upstreamed; plain append-only history |

`Build-PatchSet.ps1` treats every other `feat/windows-host/*` branch as a fix.

## Series

| Fix branch | Problem on native Windows | Upstream status |
|---|---|---|
| `os-env-lazy-tmpdir` | With `sandbox: none`, every `sys_os_*` call fails on `assert self._tmpdir is not None`. The OS-tool helper gets its config through a file in a scratch directory that only an active sandbox creates. | The same hunk and test are in omnigent-ai/omnigent#5852 (open). |
| `pi-cmd-shim` | `shutil.which("pi")` returns npm's `pi.cmd`, and Windows runs it through `cmd.exe`. A newline in `--append-system-prompt` ends the command line, so pi loses `--extension`, `--no-tools` and `--tools` and runs its own tools. | None. |

Update this table when you add, change or retire a fix.

## Patch rules

- **Minimal**: change only the lines that fix the problem. Match upstream style
  and its `AGENTS.md`.
- **Isolated**: each fix branch starts at the `<tag>` tip and touches nothing
  another fix touches. Two fixes that overlap become one fix, or the octopus
  merge fails.
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
  `git -c sequence.editor=: rebase -i --autosquash <tag>`.
- **Red first**: the fix's test fails at `<tag>` and passes with the fix.

## Add a fix

1. Create the branch at the tag, in its worktree:
   `git worktree add -b feat/windows-host/<fix> .worktrees/xanth/feat/windows-host/<fix> <tag>`
2. Write the test, then confirm it goes red at `<tag>`.
3. Make the fix, then confirm the test passes. Run the module's full test file
   and upstream's checks on the changed files, then commit.
4. Add the fix to [Series](#series) and run the [build](#build-and-push) with
   the current `<tag>`.

Done when the fix branch is a curated series on the `<tag>` tip and the build
finishes without an error.

## Build and push

`pwsh .worktrees/xanth/feat/windows-host/patch-maintenance/Build-PatchSet.ps1 -Tag <tag>`

1. Rebases each fix onto the `<tag>` tip from the base it was cut from. A fix
   already on the tip is left alone.
2. Resets `feat/windows-host/main` to the `<tag>` tip and octopus-merges every
   fix, so the tag tip is the first parent.
3. Checks the parents, and that `main` holds every fix's changes.
4. Pushes every fix and `main` in one atomic push, each with
   `--force-with-lease` on the fork's state when the run started. `-NoPush`
   skips this step.

The run is all or nothing. If a rebase, the merge, a check or the push fails,
the script resets every branch to where it started and names the cause. A
refused atomic push changes no branch on the fork. Fix the cause by hand, then
run the build again:

- **A fix does not rebase**: in its worktree, run the `git rebase --onto`
  command the script prints, resolve the conflicts, and curate the series.
- **A fix has no commits left**: upstream has it. [Retire the fix](#retire-a-fix).
- **The fixes do not merge**: the named files are changed by more than one fix.
  Make the fixes touch separate code, or combine them into one fix. Keep `main`
  free of conflict resolutions.

## Move to a new tag

1. Fetch: `git fetch origin --tags`.
2. Run the [build](#build-and-push) with `-Tag <new-tag>`, and repeat it after
   each fix by hand until it finishes without an error.
3. Curate every fix against `<new-tag>` (see [Patch rules](#patch-rules)) and
   run its tests. If any fix changed, run the build again.

Done when the build finishes without an error and
`git rev-list --parents -n 1 feat/windows-host/main` shows one merge whose first
parent is the `<new-tag>` tip and whose other parents are every fix in
[Series](#series).

## Retire a fix

When upstream makes a fix unnecessary, delete it everywhere:

1. `git worktree remove .worktrees/xanth/feat/windows-host/<fix>`
2. `git branch -D feat/windows-host/<fix>`
3. `git push xanth --delete feat/windows-host/<fix>`
4. Remove its row from [Series](#series), and run the [build](#build-and-push).

## Keep this file

This branch is public. This file and the script hold only the shared layout and
patch set maintenance. Machine setup, running from source, and personal
schedules go in the private root `AGENTS.local.md`. No machine names, user
paths or secrets.
