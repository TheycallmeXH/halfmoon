# glow_budget.ps1 - count pixels that clear the bloom gate, and the size of the
# bright core that feeds the glow chain.
#
# WHY THIS EXISTS. Every time a projectile or effect is given "more glow", the
# question that actually matters is not "does it look brighter" but "how many
# pixels now sit above the bloom threshold". That number is the budget: when it
# climbs, the glow chain stops drawing halos around objects and starts lighting
# the whole field, which reads as haze rather than as light.
#
# The threshold is not a guess. bloom_bright.gdshader extracts with
# floor_lum = 0.915 and PAPER sits at 0.9078, so on this palette "brighter than
# paper" and "glows" are the same set. Counting pixels above 0.915 is therefore
# literally counting the light sources.
#
# USAGE
#   .\.scripts\glow_budget.ps1                      # newest shot in .shots
#   .\.scripts\glow_budget.ps1 -File .shots\shot_0.png
#   .\.scripts\glow_budget.ps1 -Gate 0.90           # looser, for tuning
#
# Reports, for the whole frame:
#   gate_px     pixels at or above the gate (the light sources)
#   gate_ratio  gate_px / total px
#   clusters    connected groups of gate pixels (how many OBJECTS glow)
#
# Reported separately: the largest single cluster. One big cluster means the
# glow has merged into a blob; many small ones means it is still attached to
# objects. That distinction is the whole point -- the two produce the same
# gate_px.
param(
    [string]$File = "",
    [double]$Gate = 0.915,
    [int]$TopN = 5,
    [switch]$Raw
)

$ErrorActionPreference = "Stop"
$py = "py"

# ---- WHY -Raw EXISTS -------------------------------------------------------
#
# The final frame is NOT the right input for this measurement, and the first
# version of this script got that wrong in a way that produced confident zeros.
#
# Measured on the final (post-CRT) frame: the whole screen tops out at
# max_luma 0.8951..0.9030, because CRT applies gamma 0.835, vignette 0.30 and
# scanline 0.18 on the way out. NOTHING reaches the 0.915 gate except a
# full-screen ERASE flash (0.9604). So gate_px reads 0 for every normal frame
# and the script looks like it is working while reporting nothing.
#
# bloom_bright.gdshader does not read that frame. It reads the Screen
# SubViewport texture -- 384x216, BEFORE the CRT pass -- and it samples four
# texels with MAX (not average), precisely so a 1px core survives. That raw
# texture is where "is this pixel a light source" is actually decided, so that
# is what has to be counted.
#
# `HALFMOON_DUMP` writes those intermediate passes to user://shots as
# `screen_N.png`. Use -Raw to count on that instead:
#
#   .\.scripts\glow_budget.ps1 -Raw
#
# Verdict rule is unchanged: gate_px should rise, largest should NOT jump.

if ($Raw) {
    $rawDir = Join-Path $env:APPDATA "Godot\app_userdata\Halfmoon\shots"
    $cand = Get-ChildItem $rawDir -Filter "screen_*.png" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($null -eq $cand -or $cand.Count -eq 0) {
        Write-Output "NO_RAW  run with HALFMOON_DUMP=<t> to produce user://shots/screen_N.png"
        exit 1
    }
    $File = $cand[0].FullName
    Write-Output "RAW source: $File"
}

if ($File -eq "") {
    $shots = Get-ChildItem (Join-Path $PSScriptRoot "..\.shots") -Filter "shot_*.png" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($null -eq $shots -or $shots.Count -eq 0) {
        Write-Output "NO_SHOT  run_probe.ps1 first"
        exit 1
    }
    $File = $shots[0].FullName
}

if (-not (Test-Path $File)) {
    Write-Output "MISSING  $File"
    exit 1
}

# The analysis runs in Python because it needs per-pixel access and a flood
# fill. PowerShell 5.1 has neither.
$pyCode = @'
import sys, json
from PIL import Image

path = sys.argv[1]
gate = float(sys.argv[2])
topn = int(sys.argv[3])

im = Image.open(path).convert("RGB")
w, h = im.size
px = im.load()

# Luma with the same weights the shader comment cites (0.299/0.587/0.114).
# Not sRGB-linearised: bloom_bright reads the raw texture value, so the raw
# value is what has to be compared.
mask = [[False] * w for _ in range(h)]
count = 0
for y in range(h):
    row = mask[y]
    for x in range(w):
        r, g, b = px[x, y]
        if (0.299 * r + 0.587 * g + 0.114 * b) / 255.0 >= gate:
            row[x] = True
            count += 1

# Connected components, 4-neighbour. Iterative: the frame is 1152x648 and a
# recursive fill would blow the stack on a full-field glow.
seen = [[False] * w for _ in range(h)]
sizes = []
for y0 in range(h):
    for x0 in range(w):
        if not mask[y0][x0] or seen[y0][x0]:
            continue
        stack = [(x0, y0)]
        seen[y0][x0] = True
        n = 0
        while stack:
            cx, cy = stack.pop()
            n += 1
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = cx + dx, cy + dy
                if 0 <= nx < w and 0 <= ny < h and mask[ny][nx] and not seen[ny][nx]:
                    seen[ny][nx] = True
                    stack.append((nx, ny))
        sizes.append(n)

sizes.sort(reverse=True)
total = w * h
out = {
    "file": path,
    "size": [w, h],
    "gate": gate,
    "gate_px": count,
    "gate_ratio": round(count / total, 6),
    "clusters": len(sizes),
    "largest": sizes[:topn],
}
print(json.dumps(out))
'@

$tmp = Join-Path $env:TEMP "glow_budget.py"
[System.IO.File]::WriteAllText($tmp, $pyCode)

& $py -3 $tmp $File $Gate $TopN
