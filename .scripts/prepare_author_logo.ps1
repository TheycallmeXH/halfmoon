$ErrorActionPreference = 'Stop'
$source = 'C:/Users/12159/Pictures/new hello page/曲线.svg'
$destination = Join-Path $PSScriptRoot '../assets/menu/katuria_logo.svg'
$document = [System.Xml.XmlDocument]::new()
$document.XmlResolver = $null
$document.Load($source)
$document.DocumentElement.SetAttribute('width', '568')
$document.DocumentElement.SetAttribute('height', '144')
foreach ($element in $document.SelectNodes('//*[@style]')) {
    $element.SetAttribute('style', $element.GetAttribute('style').Replace('rgb(255,118,33)', 'rgb(33,33,30)'))
}
$document.Save($destination)
