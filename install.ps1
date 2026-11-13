# forge-kit — Windows installer for the forge JB module family (opencode)
#
# Usage (PowerShell):
#   irm <repo>/install.ps1 | iex                                     # install / refresh (idempotent)
#   & ([scriptblock]::Create((irm <repo>/install.ps1))) -Update      # hot-update modules only
#   & ([scriptblock]::Create((irm <repo>/install.ps1))) -Uninstall
#   & ([scriptblock]::Create((irm <repo>/install.ps1))) -List
#   & ([scriptblock]::Create((irm <repo>/install.ps1))) -From C:\path\to\modules
#
# Or double-click install.cmd (forwards flags, bypasses execution policy).
#
# Layout (same as the bash installer):
#   FORGE_HOME  ~\.config\opencode\forge     managed truth: modules\, registry
#   ~\.config\opencode\agent\<name>.md       symlink (or copy) -> FORGE_HOME\modules\<name>.md
#   ~\.config\opencode\opencode.json         model entries merged (Law-1 pinned)
#
# Symlink note: Windows needs admin rights OR Developer Mode for file symlinks.
# Without either, the installer falls back to copy-mode and records it in
# FORGE_HOME\linkmode.txt; `-Update` refreshes the copies too, so hot-update
# still works — you just lose the "symlink stays forever" property.

param(
    [switch]$Install,
    [switch]$Update,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$List,
    [switch]$Help,
    [string]$From = "",
    [string]$Repo = "",
    # absorbs leftover args (e.g. "--update" passed through install.cmd or iex
    # bootstrap); normalized below so both --flag and -Flag styles work.
    # Explicit Position=0 makes From/Repo named-only, so quoted flag strings
    # can never steal positional slots in scriptblock vs -File binding.
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Passthrough
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- normalize --
# Accept git-style "--update" strings: the .cmd bootstrap and the scriptblock
# one-liner both pass flags through as plain args, so map them back to switches.
for ($i = 0; $i -lt $Passthrough.Count; $i++) {
    $a = $Passthrough[$i]
    switch -Regex ($a) {
        '^--?install$'   { $Install   = $true }
        '^--?update$'    { $Update    = $true }
        '^--?uninstall$' { $Uninstall = $true }
        '^--?purge$'     { $Purge     = $true; $Uninstall = $true }
        '^--?list$'      { $List      = $true }
        '^--?h$|^--?help$' { $Help    = $true }
        '^--?from$'      { $i++; if ($i -lt $Passthrough.Count) { $From = $Passthrough[$i] } else { Write-Error "--from needs a value" } }
        '^--?repo$'      { $i++; if ($i -lt $Passthrough.Count) { $Repo = $Passthrough[$i] } else { Write-Error "--repo needs a value" } }
        default          { Write-Error "unknown flag: $a" }
    }
}
if ($Help) {
    $helpText = @"
forge-kit - Windows installer for the forge JB module family (opencode)

Usage (PowerShell):
  irm <repo>/install.ps1 | iex                                     # install / refresh (idempotent)
  & ([scriptblock]::Create((irm <repo>/install.ps1))) -Update      # hot-update modules only
  & ([scriptblock]::Create((irm <repo>/install.ps1))) -Uninstall
  & ([scriptblock]::Create((irm <repo>/install.ps1))) -List
  & ([scriptblock]::Create((irm <repo>/install.ps1))) -From C:\path\to\modules

Or double-click install.cmd (forwards flags, bypasses execution policy).

Layout (same as the bash installer):
  FORGE_HOME  ~\.config\opencode\forge     managed truth: modules\, registry
  ~\.config\opencode\agent\<name>.md       symlink (or copy) -> FORGE_HOME\modules\<name>.md
  ~\.config\opencode\opencode.json         model entries merged (Law-1 pinned)
"@
    Write-Host $helpText
    return
}

# ------------------------------------------------------------------ layout ---
$ForgeHome = if ($env:FORGE_HOME) { $env:FORGE_HOME } else { Join-Path $HOME '.config\opencode\forge' }
$AgentDir  = Join-Path $HOME '.config\opencode\agent'
$Config    = Join-Path $HOME '.config\opencode\opencode.json'
$ModulesDir = Join-Path $ForgeHome 'modules'
$LinkModeFile = Join-Path $ForgeHome 'linkmode.txt'

# Resolve HERE only when running from a real script file; `irm | iex` has no
# file, same semantics as the bash installer's BASH_SOURCE check.
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { '' }
# Repo to self-fetch (archive download, git fallback) when invoked via
# `irm | iex` (no local modules\).
$ForgeRepo = if ($Repo) { $Repo } else { 'https://github.com/RickSanchez88E/forge-kit.git' }

# module -> (model id | pinned upstream) registry; keep in sync with modules/
$DeepseekModel = 'deepseek/deepseek-v4.1-flash-1017'; $DeepseekPin = 'deepinfra/fp8'
$QwenModel     = 'qwen/qwen3.8-max-0902';             $QwenPin     = 'alibaba'
$MimoModel     = 'xiaomi/mimo-v2.6-pro';              $MimoPin     = 'deepinfra/fp8'

# ---------------------------------------------------------------- helpers ---
$script:UseColor = $false
if ($env:WT_SESSION -or $env:ConEmuANSI -or $env:ANSICON -or $PSStyle) { $script:UseColor = $true }
function Paint { param([string]$code, [string]$text)
    if ($script:UseColor) { "$([char]27)$code$text$([char]27)[0m" } else { $text }
}
function Say  { param([string]$m) Write-Host (Paint '1;32' '[forge]') $m }
function Warn { param([string]$m) Write-Host (Paint '1;33' '[forge]') $m }
# throw (not exit): under `irm | iex` an `exit` would kill the user's console
# session; under -File an uncaught throw still exits with code 1.
function Die  { param([string]$m) throw "[forge] $m" }

function Need { param([string]$cmd)
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Die "missing dependency: $cmd" }
}

function New-Timestamp { Get-Date -Format 'yyyyMMdd-HHmmss' }

function Backup { param([string]$path)
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $bak = "$path.bak-$(New-Timestamp)"
        Copy-Item -LiteralPath $path -Destination $bak
        Say "backed up: $(Split-Path $path -Leaf) -> $(Split-Path $bak -Leaf)"
    }
}

# Full-path compare, Windows-style: case-insensitive, trailing sep trimmed.
function Same-Path { param([string]$a, [string]$b)
    $fa = [IO.Path]::GetFullPath($a).TrimEnd('\', '/').ToLowerInvariant()
    $fb = [IO.Path]::GetFullPath($b).TrimEnd('\', '/').ToLowerInvariant()
    $fa -eq $fb
}

function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("forge-" + [GUID]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $d
}

# Read the recorded link mode ("symlink" | "copy"); default unknown.
function Get-LinkMode {
    if (Test-Path -LiteralPath $LinkModeFile -PathType Leaf) {
        (Get-Content -LiteralPath $LinkModeFile -Raw).Trim().ToLowerInvariant()
    } else { '' }
}
function Set-LinkMode { param([string]$mode)
    New-Item -ItemType Directory -Path $ForgeHome -Force | Out-Null
    Set-Content -LiteralPath $LinkModeFile -Value $mode -NoNewline -Encoding Ascii
}

# Run `git clone --depth 1` with EAP temporarily lowered: git writes clone
# progress to stderr, and PS 5.1 with $ErrorActionPreference='Stop' turns
# redirected native stderr into a terminating error. Direct token invocation
# (no splat) is used deliberately: pwsh 7.6.x regressed `& @array` splatting
# (array collapses to one string); direct calls work on every version.
function Invoke-GitClone { param([string]$Url, [string]$Dest)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        git clone --depth 1 $Url $Dest
        $LASTEXITCODE
    } finally { $ErrorActionPreference = $prevEap }
}

# Test whether we may create file symlinks at all (admin token or Dev Mode).
function Test-SymlinkAllowed {
    try {
        $probe = Join-Path (New-TempDir) '.lnk-probe'
        $target = Join-Path $HOME '.config\opencode'  # any existing path works
        New-Item -ItemType SymbolicLink -Path $probe -Value $target -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

# ------------------------------------------------------- module adoption -----
# Adopt a module file into FORGE_HOME and link it into agent\.
# Symlink mode when the OS allows it (matches the bash installer exactly);
# otherwise copy-mode, recorded so -Update knows to refresh agent copies.
# Existing real files at the link target are absorbed (kept as truth),
# foreign symlinks are replaced. Never destroys data.
function Adopt-Module { param([string]$Name, [string]$Src)
    $truth = Join-Path $ModulesDir "$Name.md"
    $link  = Join-Path $AgentDir  "$Name.md"

    New-Item -ItemType Directory -Path $ModulesDir, $AgentDir -Force | Out-Null

    $linkIsSymlink = $false
    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        $linkIsSymlink = ($item.LinkType -eq 'SymbolicLink')
    }

    if ($Src -and (Test-Path -LiteralPath $Src -PathType Leaf)) {
        Copy-Item -LiteralPath $Src -Destination $truth -Force
    } elseif (-not (Test-Path -LiteralPath $link) -or $linkIsSymlink) {
        # no source given and no adoptable real file at the link target
        if (-not (Test-Path -LiteralPath $truth -PathType Leaf)) {
            Warn "no source for $Name - skipped"
            return
        }
    }
    # (else: no source but an existing real agent file exists - adopt it below)

    # adopt existing real file as truth if we didn't just write one
    if (-not (Test-Path -LiteralPath $truth -PathType Leaf) -and
        (Test-Path -LiteralPath $link -PathType Leaf) -and -not $linkIsSymlink) {
        Move-Item -LiteralPath $link -Destination $truth -Force
    }
    if (-not (Test-Path -LiteralPath $truth -PathType Leaf)) {
        Warn "no truth for $Name - skipped"; return
    }

    $allowSymlink = Test-SymlinkAllowed
    if ($allowSymlink) {
        if ($linkIsSymlink) {
            if (-not (Same-Path (Get-Item -LiteralPath $link -Force).Target $truth)) {
                Remove-Item -LiteralPath $link -Force
                New-Item -ItemType SymbolicLink -Path $link -Value $truth | Out-Null
            }
        } elseif (Test-Path -LiteralPath $link) {
            # real file already there - it was copied to truth above (or adopted);
            # replace with symlink
            Backup $link
            Remove-Item -LiteralPath $link -Force
            New-Item -ItemType SymbolicLink -Path $link -Value $truth | Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $link -Value $truth | Out-Null
        }
        Set-LinkMode 'symlink'
        Say "module $Name -> $truth (symlinked into agent\)"
    } else {
        # copy fallback — same behavior as symlink for reading; -Update refreshes
        if (Test-Path -LiteralPath $link -PathType Leaf) {
            $same = $false
            try { $same = ((Get-FileHash -LiteralPath $link).Hash -eq (Get-FileHash -LiteralPath $truth).Hash) } catch { $same = $false }
            if (-not $same) { Backup $link; Copy-Item -LiteralPath $truth -Destination $link -Force }
        } else {
            Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $truth -Destination $link -Force
        }
        Set-LinkMode 'copy'
        Say "module $Name -> $truth (copy mode - no symlink privilege; -Update refreshes)"
    }
}

# ----------------------------------------------------------- config merge ---
# Pure PowerShell JSON merge (the bash one shells out to python3; on Windows
# python3 is often the Store stub, so we don't depend on it at all).
function Merge-Models {
    if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
        # fresh machine: opencode never ran - create a minimal skeleton so
        # install completes; opencode merges its defaults over this on first run.
        New-Item -ItemType Directory -Path (Split-Path $Config -Parent) -Force | Out-Null
        '{ "provider": { "openrouter": { "models": {} } } }' |
            Set-Content -LiteralPath $Config -Encoding UTF8
        Say "created skeleton opencode.json (run opencode once to finish its setup)"
    }

    $entries = [ordered]@{}
    @(
        @($DeepseekModel, $DeepseekPin),
        @($QwenModel, $QwenPin),
        @($MimoModel, $MimoPin)
    ) | ForEach-Object {
        $mid = $_[0]; $pin = $_[1]
        $entries[$mid] = [pscustomobject]@{
            name = "$mid (forge pinned $pin)"
            options = [pscustomobject]@{
                provider = [pscustomobject]@{ only = @($pin); allow_fallbacks = $false }
                reasoning = [pscustomobject]@{ enabled = $true }
            }
        }
    }

    # read current models table
    $cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfg.PSObject.Properties['provider']) {
        Add-Member -InputObject $cfg -MemberType NoteProperty -Name provider -Value ([pscustomobject]@{})
    }
    if (-not $cfg.provider.PSObject.Properties['openrouter']) {
        Add-Member -InputObject $cfg.provider -MemberType NoteProperty -Name openrouter -Value ([pscustomobject]@{})
    }
    if (-not $cfg.provider.openrouter.PSObject.Properties['models']) {
        Add-Member -InputObject $cfg.provider.openrouter -MemberType NoteProperty -Name models -Value ([pscustomobject]@{})
    }
    $models = $cfg.provider.openrouter.models

    $changed = @()
    foreach ($mid in $entries.Keys) {
        $want = (ConvertTo-Json $entries[$mid] -Depth 32 -Compress)
        $have = ''
        if ($models.PSObject.Properties[$mid]) {
            $have = (ConvertTo-Json $models.$mid -Depth 32 -Compress)
        }
        if ($want -ne $have) {
            if ($models.PSObject.Properties[$mid]) {
                $models.$mid = $entries[$mid]
            } else {
                Add-Member -InputObject $models -MemberType NoteProperty -Name $mid -Value $entries[$mid]
            }
            $changed += $mid
        }
    }

    if ($changed.Count -gt 0) {
        $ts = New-Timestamp
        Copy-Item -LiteralPath $Config -Destination "$Config.bak-$ts"
        Say "backed up: opencode.json -> opencode.json.bak-$ts"
        # drop PS5.1 BOM for maximum JSON-parser friendliness
        $json = ConvertTo-Json $cfg -Depth 32
        [IO.File]::WriteAllText($Config, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    if ($changed.Count -gt 0) { Say ("merged:" + ($changed -join ',')) } else { Say "merged:none(already current)" }
}

# ------------------------------------------------------------------- cmds ---
function Invoke-Uninstall {
    $mode = Get-LinkMode
    foreach ($name in 'deepseek-forge', 'qwen-forge', 'mimo-forge') {
        $link  = Join-Path $AgentDir "$name.md"
        $truth = Join-Path $ModulesDir "$name.md"
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if ($item.LinkType -eq 'SymbolicLink') {
                Remove-Item -LiteralPath $link -Force
                Say "removed symlink $name"
            } elseif ($mode -eq 'copy' -and (Test-Path -LiteralPath $truth -PathType Leaf)) {
                # copy-mode install: agent file is ours if content matches truth
                $ours = $false
                try { $ours = ((Get-FileHash -LiteralPath $link).Hash -eq (Get-FileHash -LiteralPath $truth).Hash) } catch { $ours = $false }
                if ($ours) {
                    Remove-Item -LiteralPath $link -Force
                    Say "removed copy-mode file $name"
                } else {
                    Warn "$name is a real file (not ours) - left untouched"
                }
            } else {
                Warn "$name is a real file (not ours) - left untouched"
            }
        }
    }
    if ($Purge) {
        if (Test-Path -LiteralPath $ForgeHome) {
            Remove-Item -LiteralPath $ForgeHome -Recurse -Force
            Say "purged $ForgeHome"
        }
    } else {
        Say "kept $ForgeHome (use -Uninstall -Purge to remove module truth)"
    }
    Say "model entries left in opencode.json - remove manually if desired"
}

function Invoke-List {
    Say "FORGE_HOME: $ForgeHome"
    $mode = Get-LinkMode
    if ($mode) { Say "link mode: $mode" }
    foreach ($name in 'deepseek-forge', 'qwen-forge', 'mimo-forge') {
        $link  = Join-Path $AgentDir "$name.md"
        $truth = Join-Path $ModulesDir "$name.md"
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if ($item.LinkType -eq 'SymbolicLink') {
                $ok = Test-Path -LiteralPath $truth -PathType Leaf
                Write-Host ("  {0}: symlink -> {1} {2}" -f $name, $item.Target, $(if ($ok) { '[OK]' } else { '[BROKEN]' }))
            } else {
                Write-Host ("  {0}: copy (copy-mode install)" -f $name)
            }
        } else {
            Write-Host ("  {0}: not installed" -f $name)
        }
    }
}

# Download a branch archive of $ForgeRepo and extract it; needs nothing but
# inbox PowerShell (Invoke-WebRequest + Expand-Archive). Returns extracted
# repo root, or $null on failure. Tries main then master branch names.
function Invoke-SelfFetch {
    $prevEap = $ErrorActionPreference
    $prevProgress = $ProgressPreference
    $ErrorActionPreference = 'Continue'
    $ProgressPreference = 'SilentlyContinue'   # PS5.1 renders IWR progress per-byte; it cripples downloads
    # some Win8.1/old-Win10 builds negotiate pre-1.2 TLS; github needs 1.2
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    try {
        $tmpRoot = New-TempDir
        $zip = Join-Path $tmpRoot 'forge-kit.zip'
        foreach ($branch in 'main', 'master') {
            $url = ($ForgeRepo -replace '\.git$', '') + "/archive/refs/heads/$branch.zip"
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip -ErrorAction Stop
                Expand-Archive -LiteralPath $zip -DestinationPath $tmpRoot -Force -ErrorAction Stop
                Say "downloaded source archive ($branch branch) - no git needed"
                return (Join-Path $tmpRoot "forge-kit-$branch")
            } catch { }   # 404 / network blip - try next strategy
        }
    } finally {
        $ErrorActionPreference = $prevEap
        $ProgressPreference = $prevProgress
    }
    return $null
}

function Resolve-Source { param([string]$src)
    # source resolution: explicit -From > bundled modules\ next to script > self-fetch
    if (-not $src) {
        if ($Here -and (Test-Path -LiteralPath (Join-Path $Here 'modules') -PathType Container)) {
            return (Join-Path $Here 'modules')
        }
        # primary: archive download - zero dependencies
        $repoRoot = Invoke-SelfFetch
        if ($repoRoot) {
            return (Join-Path $repoRoot 'modules')
        }
        # fallback: git clone (handles custom FORGE_REPO layouts the zip guess missed)
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $tmp = Join-Path (New-TempDir) 'forge-kit'
            $rc = Invoke-GitClone $ForgeRepo $tmp
            if ($rc -ne 0) { Die "self-fetch failed: archive download + git clone both failed for $ForgeRepo" }
            Say "self-cloned from $ForgeRepo"
            return (Join-Path $tmp 'modules')
        }
        Die "could not fetch source and git is not installed. install git: winget install --id Git.Git -e  (or download from https://git-scm.com/download/win)"
    }
    # remote source (git URL) support: shallow clone to a temp dir
    if ($src -match '^(https?://|git@)') {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Die "--from <git-url> needs git: winget install --id Git.Git -e  (local paths need no git)"
        }
        $tmp = Join-Path (New-TempDir) 'forge-src'
        $rc = Invoke-GitClone $src $tmp
        if ($rc -ne 0) { Die "git clone failed: $src" }
        return $tmp
    }
    $src
}

function Invoke-Install { param([string]$src)
    $src = Resolve-Source $src
    if (-not ($src -and (Test-Path -LiteralPath $src -PathType Container))) {
        Die "module source not found: $src"
    }

    Adopt-Module 'deepseek-forge' (Join-Path $src 'deepseek-forge.md')
    Adopt-Module 'qwen-forge'     (Join-Path $src 'qwen-forge.md')
    Adopt-Module 'mimo-forge'     (Join-Path $src 'mimo-forge.md')

    Merge-Models

    Write-Host ''
    Say "install complete. usage:"
    Write-Host "    in opencode (TUI or app):  @deepseek-forge <task>   (spawn FOREGROUND only)"
    Write-Host "    hot-update:                install.ps1 -Update  (or -From <src>)"
    Write-Host "    status:                    install.ps1 -List"
}

function Invoke-Update { param([string]$src)
    # replace module truth under FORGE_HOME; links/copies refreshed;
    # new sessions pick it up
    if (-not $src) {
        if ($Here -and (Test-Path -LiteralPath (Join-Path $Here 'modules') -PathType Container)) {
            $src = Join-Path $Here 'modules'
        }
    }
    if (-not $src) { Die "no module source - run from a repo checkout or pass -From <src>" }
    if (-not (Test-Path -LiteralPath $ModulesDir -PathType Container)) { Die "not installed - run install first" }

    $mode = Get-LinkMode
    foreach ($name in 'deepseek-forge', 'qwen-forge', 'mimo-forge') {
        $m = Join-Path $src "$name.md"
        if (Test-Path -LiteralPath $m -PathType Leaf) {
            Copy-Item -LiteralPath $m -Destination (Join-Path $ModulesDir "$name.md") -Force
            Say "updated $name"
            # copy-mode installs: the agent copy IS the consumed artifact
            if ($mode -eq 'copy') {
                $link = Join-Path $AgentDir "$name.md"
                if (Test-Path -LiteralPath $link -PathType Leaf) {
                    Copy-Item -LiteralPath (Join-Path $ModulesDir "$name.md") -Destination $link -Force
                }
            }
        }
    }
    Say "links untouched - new opencode sessions load the new specs"
}

# ------------------------------------------------------------------- main ---
if     ($List)      { Invoke-List }
elseif ($Uninstall) { Invoke-Uninstall }
elseif ($Update)    { Invoke-Update $From }
else                { Invoke-Install $From }   # default & explicit -Install
