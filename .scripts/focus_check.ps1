param([string]$File = "shots\tmp\final.png")

Add-Type -AssemblyName System.Drawing
$path = (Resolve-Path $File -ErrorAction SilentlyContinue)
if (-not $path) {
    Write-Output "FILE NOT FOUND: $File"
    exit 1
}

$bmp = [System.Drawing.Bitmap]::FromFile($path)
$W = $bmp.Width
$H = $bmp.Height

# Sharpness = mean |horizontal luminance gradient|. A focused region keeps its
# 1px structure and scores high; a defocused one is smoothed and scores low.
# The CRT's focus field is 0 at centre and 1 at the corners, so the EXPECTED
# relation is: centre SHARPEST, corners MUCH SOFTER. Corners scoring higher
# than the centre means the field is inverted or suppressed.
function Sharp([System.Drawing.Bitmap]$b, [int]$x0, [int]$y0, [int]$x1, [int]$y1) {
    $sum = 0.0
    $n = 0
    for ($y = $y0; $y -lt $y1; $y++) {
        for ($x = $x0; $x -lt ($x1 - 1); $x++) {
            $a = $b.GetPixel($x, $y)
            $c = $b.GetPixel($x + 1, $y)
            $la = 0.299 * $a.R + 0.587 * $a.G + 0.114 * $a.B
            $lc = 0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B
            $sum += [Math]::Abs($la - $lc)
            $n++
        }
    }
    if ($n -eq 0) { return 0.0 }
    return [Math]::Round($sum / $n, 2)
}

# Clamp sample windows so a smaller image cannot run past its edge.
$cx0 = [Math]::Min(640, $W - 60); $cy0 = [Math]::Min(380, $H - 60)
$centre     = Sharp $bmp $cx0 $cy0 ($cx0 + 100) ($cy0 + 80)
$topRight   = Sharp $bmp ([Math]::Max(0, $W - 152)) 70 ([Math]::Max(0, $W - 52)) 150
$bottomLeft = Sharp $bmp 100 ([Math]::Max(0, $H - 108)) 200 ([Math]::Max(0, $H - 38))

"REGION        SHARPNESS   (lower = softer / more defocused)"
"centre        {0,8}" -f $centre
"top-right     {0,8}" -f $topRight
"bottom-left   {0,8}" -f $bottomLeft
""

$softer = 0
$harsher = 0
foreach ($v in @($topRight, $bottomLeft)) {
    if ($v -lt $centre) { $softer++ } else { $harsher++ }
}
if ($harsher -eq 0) {
    "VERDICT: OK - both corners softer than centre (defocus is working)."
} elseif ($softer -eq 0) {
    "VERDICT: BAD - both corners SHARPER than centre (defocus inverted or absent)."
} else {
    "VERDICT: MIXED - one corner softer, one sharper. Check for a mask seam."
}

$bmp.Dispose()
