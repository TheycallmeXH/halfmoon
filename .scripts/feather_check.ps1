param([string]$File = ".shots\chk-moontop.png")

Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Bitmap]::FromFile((Resolve-Path $File))
$W = $img.Width
$H = $img.Height

# The border exemption in focus_field feathers between 50 and 80 SOURCE
# pixels. If that feather is visible, texture variance would step between
# those two distances on flat paper. In the final frame one source pixel is
# 3 screen pixels (integer upscale), so scan those rows.
function BandSD([int]$fy, [int]$x0, [int]$x1) {
    $R = New-Object 'System.Collections.Generic.List[double]'
    $G = New-Object 'System.Collections.Generic.List[double]'
    $B = New-Object 'System.Collections.Generic.List[double]'
    for ($x = $x0; $x -lt $x1; $x += 3) {
        $c = $img.GetPixel($x, $fy)
        $R.Add($c.R); $G.Add($c.G); $B.Add($c.B)
    }
    function StdDev($list) {
        $m = ($list | Measure-Object -Average).Average
        $s = 0.0
        foreach ($v in $list) { $s += ($v - $m) * ($v - $m) }
        return [Math]::Round([Math]::Sqrt($s / $list.Count), 2)
    }
    return @((StdDev $R), (StdDev $G), (StdDev $B))
}

"srcDist  finalY   sd(R,G,B) across flat paper"
foreach ($d in 20, 30, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 100) {
    $fy = $d * 3
    if ($fy -ge $H) { continue }
    $sd = BandSD $fy 260 470
    "{0,7} {1,7}   ({2}, {3}, {4})" -f $d, $fy, $sd[0], $sd[1], $sd[2]
}

$img.Dispose()
