#Requires -Version 5.1

<#
.SYNOPSIS
    Builds the logo files from the master image: transparent PNGs, the window icon and the GitHub social preview.
.DESCRIPTION
    The master is a gold line drawing on black. Black becomes transparent (alpha from the
    brightest channel, colour un-premultiplied), the drawing is cropped to its bounds and
    padded to a square. Writes:
      PathShrink\gui\logo.png        256 px, used by the window
      PathShrink\gui\PathShrink.ico  16-256 px, window and shortcut icon
      docs\brand\logo.png            1024 px
      docs\brand\social.png          1280 x 640, for the repository social preview
.PARAMETER Source
    The master image (jpg or png, gold on black).
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Source)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repo = Split-Path $PSScriptRoot -Parent

$src = New-Object Drawing.Bitmap $Source
$w = $src.Width; $h = $src.Height
$rect = New-Object Drawing.Rectangle 0, 0, $w, $h
$data = $src.LockBits($rect, 'ReadOnly', [Drawing.Imaging.PixelFormat]::Format32bppArgb)
$px = New-Object byte[] ($data.Stride * $h)
[Runtime.InteropServices.Marshal]::Copy($data.Scan0, $px, 0, $px.Length)
$src.UnlockBits($data); $src.Dispose()

# Black to transparent, and the bounds of everything visible.
$minX = $w; $minY = $h; $maxX = 0; $maxY = 0
for ($y = 0; $y -lt $h; $y++) {
    $row = $y * $data.Stride
    for ($x = 0; $x -lt $w; $x++) {
        $i = $row + $x * 4
        $b = $px[$i]; $g = $px[$i + 1]; $r = $px[$i + 2]
        $a = [Math]::Max($r, [Math]::Max($g, $b))
        if ($a -lt 18) { $px[$i + 3] = 0; continue }
        $px[$i] = [byte][Math]::Min(255, $b * 255 / $a)
        $px[$i + 1] = [byte][Math]::Min(255, $g * 255 / $a)
        $px[$i + 2] = [byte][Math]::Min(255, $r * 255 / $a)
        $px[$i + 3] = [byte]$a
        if ($a -gt 60) { if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }; if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y } }
    }
}
$clear = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
$d2 = $clear.LockBits($rect, 'WriteOnly', [Drawing.Imaging.PixelFormat]::Format32bppArgb)
[Runtime.InteropServices.Marshal]::Copy($px, 0, $d2.Scan0, $px.Length)
$clear.UnlockBits($d2)

$side = [Math]::Max($maxX - $minX, $maxY - $minY)
$pad = [int]($side * 0.03)
$side += 2 * $pad
$cx = ($minX + $maxX) / 2; $cy = ($minY + $maxY) / 2
$crop = New-Object Drawing.RectangleF ($cx - $side / 2), ($cy - $side / 2), $side, $side

function Save-Square([int]$Size, [string]$Path) {
    $bmp = New-Object Drawing.Bitmap $Size, $Size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gr = [Drawing.Graphics]::FromImage($bmp)
    $gr.InterpolationMode = 'HighQualityBicubic'; $gr.PixelOffsetMode = 'HighQuality'; $gr.SmoothingMode = 'HighQuality'
    $gr.DrawImage($clear, (New-Object Drawing.RectangleF 0, 0, $Size, $Size), $crop, [Drawing.GraphicsUnit]::Pixel)
    $gr.Dispose()
    if ($Path) { $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png) }
    $bmp
}
function Get-PngBytes($Bitmap) { $ms = New-Object IO.MemoryStream; $Bitmap.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $ms.ToArray() }

$gui = Join-Path $repo 'PathShrink\gui'
$brand = Join-Path $repo 'docs\brand'
New-Item -ItemType Directory -Path $brand -Force | Out-Null
(Save-Square 256 (Join-Path $gui 'logo.png')).Dispose()
(Save-Square 1024 (Join-Path $brand 'logo.png')).Dispose()

# ICO with PNG frames (Windows Vista and later read them).
$sizes = 16, 24, 32, 48, 64, 256
$frames = foreach ($s in $sizes) { $b = Save-Square $s $null; Get-PngBytes $b; $b.Dispose() }
$ms = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter $ms
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $frames[$i].Length
    $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($f in $frames) { $bw.Write([byte[]]$f) }
[IO.File]::WriteAllBytes((Join-Path $gui 'PathShrink.ico'), $ms.ToArray())

# Social preview: logo on the window background with the name and the one-line pitch.
$soc = New-Object Drawing.Bitmap 1280, 640
$gr = [Drawing.Graphics]::FromImage($soc)
$gr.SmoothingMode = 'HighQuality'; $gr.InterpolationMode = 'HighQualityBicubic'; $gr.TextRenderingHint = 'AntiAliasGridFit'
$gr.Clear([Drawing.Color]::FromArgb(22, 22, 24))
$logo = Save-Square 360 $null
$gr.DrawImage($logo, 110, 140, 360, 360)
$gold = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(226, 196, 138))
$grey = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(184, 184, 188))
$gr.DrawString('PathShrink', (New-Object Drawing.Font 'Segoe UI Light', 80, ([Drawing.FontStyle]::Regular), ([Drawing.GraphicsUnit]::Pixel)), $gold, 528, 205)
$gr.DrawString("Find and fix OneDrive and SharePoint paths`nover the 400-character limit.", (New-Object Drawing.Font 'Segoe UI', 30, ([Drawing.FontStyle]::Regular), ([Drawing.GraphicsUnit]::Pixel)), $grey, 536, 322)
$gr.Dispose()
$soc.Save((Join-Path $brand 'social.png'), [Drawing.Imaging.ImageFormat]::Png)
$soc.Dispose(); $logo.Dispose(); $clear.Dispose()
Write-Host 'Logo assets written'
