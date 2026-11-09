$p = "$env:APPDATA\Godot\app_userdata\Halfmoon\shots\path.csv"
$rows = Import-Csv $p
$n = $rows.Count
$ys = New-Object 'double[]' $n
for ($i = 0; $i -lt $n; $i++) { $ys[$i] = [double]$rows[$i].y }
$min = ($ys | Measure-Object -Minimum).Minimum
$max = ($ys | Measure-Object -Maximum).Maximum

$cols = 160
$lines = 40
$grid = New-Object 'char[][]' $lines
for ($r = 0; $r -lt $lines; $r++) {
    $grid[$r] = New-Object 'char[]' $cols
    for ($c = 0; $c -lt $cols; $c++) { $grid[$r][$c] = ' ' }
}

for ($i = 0; $i -lt $n; $i++) {
    $col = [int](($cols - 1) * $i / [double]$n)
    $t = ($ys[$i] - $min) / ($max - $min + 0.0001)
    $row = [int](($lines - 1) * (1.0 - $t))
    if ($row -lt 0) { $row = 0 }
    if ($row -ge $lines) { $row = $lines - 1 }
    $grid[$row][$col] = '#'
}

"y range {0:F2}..{1:F2}  span {2:F2}  frames {3}" -f $min, $max, ($max-$min), $n
for ($r = 0; $r -lt $lines; $r++) { -join $grid[$r] }
