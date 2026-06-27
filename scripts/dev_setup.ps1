# Wires the kajmak addon into the func_godot_test_project submodule so Godot can
# load and run it. Safe to re-run.
#
# These changes live INSIDE the submodule working tree (a junction + a one-line
# project.godot edit), so they are not tracked by this repo and must be recreated
# after a fresh `git clone --recursive`. Run this once after cloning:
#
#   git submodule update --init --recursive
#   pwsh scripts/dev_setup.ps1
#
# The submodule is configured with `ignore = dirty` in .gitmodules so these local
# edits don't show up as changes in the superproject.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repo "external\func_godot_test_project"
$addonLink = Join-Path $project "addons\kajmak"
$addonTarget = Join-Path $repo "addons\kajmak"

# 1. Junction so res://addons/kajmak resolves inside the test project.
if (Test-Path $addonLink) {
    Write-Host "Junction already exists: $addonLink"
} else {
    New-Item -ItemType Junction -Path $addonLink -Target $addonTarget | Out-Null
    Write-Host "Created junction: $addonLink -> $addonTarget"
}

# 2. Enable the kajmak plugin in the test project's project.godot.
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
Write-Host '  & <godot> --headless --path external/func_godot_test_project --script res://addons/kajmak/test/verify_skeleton.gd'
