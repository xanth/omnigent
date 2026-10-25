#Requires -Version 7.4
<#
.SYNOPSIS
Moves the Windows host patch set onto a release tag and pushes it.

.DESCRIPTION
Fix branches are every local feat/windows-host/* branch except main and patch-maintenance.
Every fix branch and main must be checked out, clean, in its own worktree.

1. Rebases each fix onto the tag tip from the base it was cut from: the parent of its first
   own commit, where own commits are on no origin branch or tag. A fix already on the tag
   tip is left alone.
2. Resets main to the tag tip and octopus-merges every fix, so the tag tip is the first
   parent.
3. Checks the parents and that main holds every fix's changes.
4. Pushes every fix and main to the fork in one atomic push, each with --force-with-lease
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
$composite = "$prefix/main"
$notFixes = @($composite, "$prefix/patch-maintenance")

function Invoke-Git { git -C $PSScriptRoot @args }
function Get-OwnCommit([string] $ref) { @(Invoke-Git rev-list --reverse $ref --not --remotes=origin --tags) }

$tagTip = Invoke-Git rev-parse "$Tag^{commit}"
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
        if ($base -eq $tagTip) { continue }
        try { git -C $worktrees[$fix] rebase --quiet --onto $tagTip $base }
        catch { throw "$fix does not rebase cleanly onto $Tag. In its worktree run: git rebase --onto $Tag $base" }
    }

    $fixTips = foreach ($fix in $fixes) {
        $commits = @(Invoke-Git rev-list --reverse "$tagTip..$fix")
        if ($commits.Count -eq 0) { throw "$fix has no commits left on $Tag, so upstream has it. Retire it." }
        $merges = @(Invoke-Git rev-list --merges "$tagTip..$fix")
        if (@(Get-OwnCommit $fix).Count -ne $commits.Count -or $merges.Count -gt 0 -or
            (Invoke-Git rev-parse "$($commits[0])^") -ne $tagTip) {
            throw "$fix must be a linear series of its own commits on the $Tag tip."
        }
        Invoke-Git rev-parse $fix
    }

    $main = $worktrees[$composite]
    git -C $main reset --hard --quiet $tagTip
    try { git -C $main merge --no-ff --quiet -m "Merge Windows host patch set onto $Tag" @fixes }
    catch {
        $shared = $fixes | ForEach-Object { Invoke-Git diff --name-only $tagTip $_ } |
            Group-Object | Where-Object Count -gt 1 | ForEach-Object Name
        throw "The fixes do not merge cleanly. Files changed by more than one fix: $($shared -join ', ')"
    }

    $parents = @((git -C $main rev-list --parents -n 1 HEAD) -split ' ' | Select-Object -Skip 1)
    if ($parents[0] -ne $tagTip -or (Compare-Object $parents[1..($parents.Count - 1)] $fixTips)) {
        throw "Composite parents do not match: $parents"
    }
    foreach ($fix in $fixes) {
        $paths = @(Invoke-Git diff --name-only $tagTip $fix)
        $differing = @(git -C $main diff --name-only $fix HEAD -- @paths)
        if ($differing.Count -gt 0) { throw "Composite is missing $fix changes in: $differing" }
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
