param([string]$File = ".shots\bright2.png")

Add-Type -AssemblyName System.Drawing
$b = [System.Drawing.Bitmap]::FromFile((Resolve-Path $File))
$W = $b.Width
$H = $b.Height

# Chroma is a SPATIAL effect: neighbouring texels get pushed in opposite
# directions, so R-B varies across the frame. A uniform tint also offsets R-B,
# but it does so CONSTANTLY, so it contributes nothing to the variance.
# Measuring the variance is therefore the only way to tell "no fringe" from
# "tint shift".
function ChromaVar([int]$x0, [int]$x1) {
    $vals = New-Object 'System.Collections.Generic.List[double]'
    for ($y = 30; $y -lt ($H - 30); $y += 3) {
        for ($x = $x0; $x -lt $x1; $x += 1) {
            $c = $b.GetPixel($x, $y)
            $vals.Add([double]($c.R - $c.B))
        }
    }
    $mean = ($vals | Measure-Object -Average).Average
    $var = 0.0
    foreach ($v in $vals) { $var += ($v - $mean) * ($v - $mean) }
    $var = $var / $vals.Count
    return @([Math]::Round($mean, 2), [Math]::Round([Math]::Sqrt($var), 2), [Math]::Round(($vals | Measure-Object -Maximum).Maximum, 1), [Math]::Round(($vals | Measure-Object -Minimum).Minimum, 1))
}

$left = ChromaVar 14 130
$mid = ChromaVar 520 640
"left rim  R-B mean={0} sd={1} max={2} min={3}" -f $left[0], $left[1], $left[2], $left[3]
"mid field R-B mean={0} sd={1} max={2} min={3}" -f $mid[0], $mid[1], $mid[2], $mid[3]
$b.Dispose()
