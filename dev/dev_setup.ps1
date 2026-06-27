# Wires the kajmak addon and dev scripts into the func_godot_test_project
# submodule so Godot can load and run them. Safe to re-run.
#
# These changes live INSIDE the submodule working tree (junctions + a one-line
# project.godot edit), so they are not tracked by this repo and must be recreated
# after a fresh `git clone --recursive`. Run this once after cloning:
#
#   git submodule update --init --recursive
#   pwsh dev/dev_setup.ps1
#
# The submodule is configured with `ignore = dirty` in .gitmodules so these local
# edits don't show up as changes in the superproject.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repo "external\func_godot_test_project"

function Ensure-Junction($link, $target) {
    if (Test-Path $link) {
        Write-Host "Junction already exists: $link"
    } else {
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Write-Host "Created junction: $link -> $target"
    }
}

# 1. Junction the shippable addon so res://addons/kajmak resolves in the project.
Ensure-Junction (Join-Path $project "addons\kajmak") (Join-Path $repo "addons\kajmak")

# 2. Junction the dev folder so res://dev (verify scripts, etc.) resolves.
Ensure-Junction (Join-Path $project "dev") (Join-Path $repo "dev")

# 3. Enable the kajmak plugin in the test project's project.godot.
$projectGodot = Join-Path $project "project.godot"
$content = Get-Content $projectGodot -Raw
if ($content -match "addons/kajmak/plugin.cfg") {
    Write-Host "Plugin already enabled in project.godot"
} else {
    $content = $content -replace '(enabled=PackedStringArray\("res://addons/func_godot/plugin.cfg")', '$1, "res://addons/kajmak/plugin.cfg"'
    Set-Content -Path $projectGodot -Value $content -NoNewline -Encoding utf8
    Write-Host "Enabled kajmak plugin in project.godot"
}

Write-Host "`nDone. Open the project in Godot 4.5+ or run the verify script:"
Write-Host '  & <godot> --headless --path external/func_godot_test_project --script res://dev/verify_skeleton.gd'
