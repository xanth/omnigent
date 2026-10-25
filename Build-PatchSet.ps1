#Requires -Version 7.4
<#
.SYNOPSIS
Moves the Windows host patch set onto a release tag and pushes it.

.DESCRIPTION
Fix branches are every local feat/windows-host/* branch except release and patch-maintenance.
Every fix branch and release must be checked out, clean, in its own worktree.

Fixes are based on the tag's fork point: where the tag's release branch left upstream main
(git merge-base <tag> origin/main). A pull request from a fix to upstream main then carries
only the fix's own commits, and merging the fix onto the tag tip adds only the fix.

1. Rebases each fix onto the fork point from the base it was cut from: the parent of its
   first own commit, where own commits are on no origin branch or tag. A fix already on the
   fork point is left alone.
2. Checks that no two fixes change the same file.
3. Resets release to the tag tip and octopus-merges every fix, so the tag tip is the first
   parent.
4. Checks the parents, and that release changes each fix's files exactly as the fix does.
5. Pushes every fix and release to the fork in one atomic push, each with --force-with-lease
   on the fork's state when the run started, unless -NoPush.

All or nothing: if a rebase, the merge, a check or the push fails, the script aborts it,
resets every branch to where it started, and names the cause. An atomic push that fails
updates no branch on the fork. Fix the affected branches by hand, then run it again.

.EXAMPLE
pwsh Build-PatchSet.ps1 -Tag v0.20.0
#>
param(
    [Parameter(Mandatory)]
    [string] $Tag,
    [switch] $NoPush
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$fork = 'xanth'
$prefix = 'feat/windows-host'
$composite = "$prefix/release"
$notFixes = @($composite, "$prefix/patch-maintenance")

function Invoke-Git { git -C $PSScriptRoot @args }
function Get-OwnCommit([string] $ref) { @(Invoke-Git rev-list --reverse $ref --not --remotes=origin --tags) }
function Get-PatchId { @(Invoke-Git diff @args | git -C $PSScriptRoot patch-id --stable) -split ' ' | Select-Object -First 1 }

Invoke-Git fetch --quiet origin
$tagTip = Invoke-Git rev-parse "$Tag^{commit}"
$forkPoint = Invoke-Git merge-base $tagTip refs/remotes/origin/main
$fixes = @(Invoke-Git for-each-ref --format='%(refname:short)' "refs/heads/$prefix/" |
    Where-Object { $_ -notin $notFixes })
if ($fixes.Count -eq 0) { throw "No fix branches match $prefix/*." }
$branches = @($fixes) + $composite

$worktrees = @{}
foreach ($line in Invoke-Git worktree list --porcelain) {
    if ($line -like 'worktree *') { $path = $line.Substring(9) }
    elseif ($line -like 'branch refs/heads/*') { $worktrees[$line.Substring(18)] = $path }
}
$start = @{}
foreach ($branch in $branches) {
    if (-not $worktrees[$branch]) { throw "No worktree has $branch checked out." }
    if (git -C $worktrees[$branch] status --porcelain) { throw "$($worktrees[$branch]) has uncommitted changes." }
    $start[$branch] = Invoke-Git rev-parse $branch
}
if (-not $NoPush) {
    Invoke-Git fetch --quiet $fork
    $leases = foreach ($branch in $branches) {
        "--force-with-lease=refs/heads/${branch}:$(Invoke-Git for-each-ref --format='%(objectname)' "refs/remotes/$fork/$branch")"
    }
}

try {
    foreach ($fix in $fixes) {
        $own = @(Get-OwnCommit $fix)
        if ($own.Count -eq 0) { throw "$fix has no commits of its own. Retire it." }
        $base = Invoke-Git rev-parse "$($own[0])^"
        if ($base -eq $forkPoint) { continue }
        try { git -C $worktrees[$fix] rebase --quiet --onto $forkPoint $base }
        catch { throw "$fix does not rebase cleanly onto the $Tag fork point. In its worktree run: git rebase --onto $forkPoint $base" }
    }

    $fixTips = foreach ($fix in $fixes) {
        $commits = @(Invoke-Git rev-list --reverse "$forkPoint..$fix")
        if ($commits.Count -eq 0) { throw "$fix has no commits left on the $Tag fork point, so upstream has it. Retire it." }
        $merges = @(Invoke-Git rev-list --merges "$forkPoint..$fix")
        if (@(Get-OwnCommit $fix).Count -ne $commits.Count -or $merges.Count -gt 0 -or
            (Invoke-Git rev-parse "$($commits[0])^") -ne $forkPoint) {
            throw "$fix must be a linear series of its own commits on the $Tag fork point."
        }
        Invoke-Git rev-parse $fix
    }

    $fixPaths = @{}
    foreach ($fix in $fixes) { $fixPaths[$fix] = @(Invoke-Git diff --name-only $forkPoint $fix) }
    $shared = $fixes | ForEach-Object { $fixPaths[$_] } | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name
    if ($shared) { throw "Files changed by more than one fix: $($shared -join ', ')" }

    $release = $worktrees[$composite]
    git -C $release reset --hard --quiet $tagTip
    try { git -C $release merge --no-ff --quiet -m "Merge Windows host patch set onto $Tag" @fixes }
    catch { throw "The fixes do not merge cleanly onto $Tag." }

    $parents = @((git -C $release rev-list --parents -n 1 HEAD) -split ' ' | Select-Object -Skip 1)
    if ($parents[0] -ne $tagTip -or (Compare-Object $parents[1..($parents.Count - 1)] $fixTips)) {
        throw "Composite parents do not match: $parents"
    }
    foreach ($fix in $fixes) {
        $paths = $fixPaths[$fix]
        if ((Get-PatchId $forkPoint $fix '--' @paths) -ne (Get-PatchId $tagTip $composite '--' @paths)) {
            throw "Composite does not change $($paths -join ', ') exactly as $fix does."
        }
    }

    if (-not $NoPush) {
        try { Invoke-Git push --quiet --atomic @leases $fork @branches }
        catch { throw "The push to $fork was refused, so the fork still has the old version of every branch." }
    }
}
catch {
    $PSNativeCommandUseErrorActionPreference = $false
    foreach ($branch in $branches) {
        $worktree = $worktrees[$branch]
        $gitDir = git -C $worktree rev-parse --absolute-git-dir
        if ((Test-Path "$gitDir/rebase-merge") -or (Test-Path "$gitDir/rebase-apply")) {
            git -C $worktree rebase --abort 2>$null
        }
        git -C $worktree reset --hard --quiet $start[$branch]
    }
    throw "$($_.Exception.Message) Every branch is back where it started."
}

git -C $worktrees[$composite] log --graph --format='%h %s' -n ($fixes.Count + 2)
