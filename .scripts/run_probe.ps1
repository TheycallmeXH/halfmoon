param(
    [int]$Seconds = 6,
    [hashtable]$Vars = @{},
    [string]$Resolution = "1152x648"
)

$godot = "D:\godot\Godot_v4.7-stable_win64.exe"
$userShots = "$env:APPDATA\Godot\app_userdata\Halfmoon\shots"
$localShots = Join-Path $PSScriptRoot "..\.shots"

New-Item -ItemType Directory -Force -Path $userShots | Out-Null
New-Item -ItemType Directory -Force -Path $localShots | Out-Null
Remove-Item "$userShots\*.png" -Force -ErrorAction SilentlyContinue
Remove-Item "$localShots\*.png" -Force -ErrorAction SilentlyContinue

# NOTE: this parameter MUST NOT be called $Env. In PowerShell `$Env:` is the
# environment-variable provider, and a parameter of that name shadows it — the
# loop below would then iterate the parameter hashtable while writing values
# through $Env[$k], i.e. set nothing at all. It was named `$Env` for a while and
# silently swallowed every variable, which is why HALFMOON_DUMP appeared to stop
# working: the runs succeeded only because earlier manual sets were still in the
# process environment.

# Child gets its own inherited block; set them for THIS scope before launching.
$saved = @{}
foreach ($key in $Vars.Keys) {
    $saved[$key] = [System.Environment]::GetEnvironmentVariable($key)
    [System.Environment]::SetEnvironmentVariable($key, [string]$Vars[$key])
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $godot
# Quote the project path: it contains a space, and an unquoted --path splits at
# that space so Godot receives a path that does not exist.
$psi.Arguments = "--path `"D:/Godot project/deepseek-test`" --resolution $Resolution"
$psi.UseShellExecute = $false
$psi.WorkingDirectory = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
# Environment: rely on plain inheritance.
#
# `$psi.EnvironmentVariables` cannot be filled here — under Windows PowerShell
# 5.1 (this machine) it is null for a non-shell process, so indexing it throws.
# Inheritance from the parent block is what the manual launch relies on too, so
# the variables are simply set in THIS process before Start and restored
# afterwards; the child copies them at spawn time.
$proc = [System.Diagnostics.Process]::Start($psi)

Start-Sleep -Seconds $Seconds
if (-not $proc.HasExited) {
    $proc.Kill()
    Start-Sleep -Milliseconds 900
}

foreach ($key in $saved.Keys) {
    [System.Environment]::SetEnvironmentVariable($key, $saved[$key])
}

Get-ChildItem $userShots -File -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $localShots $_.Name) -Force
    $_.Name
}
