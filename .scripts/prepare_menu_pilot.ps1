param(
    [string]$Source = 'C:/Users/12159/Downloads/9998205687142060-0dabff2b-7daf-4c26-9cbe-c3c08f1c2312-image_task_01M72P2T9Z44KVDY4JV4H2DMN3_0.png',
    [string]$Destination = 'D:/Godot project/deepseek-test/assets/menu/pilot_portrait.png'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$drawingReferences = @(
    [System.Drawing.Bitmap].Assembly.Location,
    [System.Drawing.Rectangle].Assembly.Location,
    (Join-Path (Split-Path ([System.Drawing.Bitmap].Assembly.Location)) 'System.Private.Windows.GdiPlus.dll'),
    (Join-Path (Split-Path ([System.Drawing.Bitmap].Assembly.Location)) 'System.Private.Windows.Core.dll'),
    'System.Runtime',
    'System.Runtime.InteropServices'
)
Add-Type -ReferencedAssemblies $drawingReferences -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class MenuPilotArt {
    public static void Prepare(string source, string destination) {
        using (var original = new Bitmap(source))
        using (var image = original.Clone(new Rectangle(0, 0, original.Width, original.Height),
                                          PixelFormat.Format32bppArgb)) {
            if (image.Width != 2048 || image.Height != 1536)
                throw new InvalidOperationException("Unexpected reference image dimensions.");
            const int cropX = 16;
            const int width = 1632;
            int height = image.Height;
            var inputBits = image.LockBits(new Rectangle(0, 0, image.Width, height),
                                          ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            var input = new byte[inputBits.Stride * height];
            Marshal.Copy(inputBits.Scan0, input, 0, input.Length);
            image.UnlockBits(inputBits);
            var output = new byte[width * height * 4];
            for (int y = 0; y < height; y++) {
                int left = width, right = -1;
                for (int x = 0; x < width; x++) {
                    int sourceX = cropX + x;
                    // The reference's dialogue box is separate from the character.
                    if (sourceX >= 1175 && y >= 60 && y < 375) continue;
                    int i = y * inputBits.Stride + sourceX * 4;
                    int luminance = (input[i] * 114 + input[i + 1] * 587 + input[i + 2] * 299) / 1000;
                    if (luminance > 140) {
                        left = Math.Min(left, x);
                        right = x;
                    }
                }
                if (right < left) continue;
                left = Math.Max(0, left - 2);
                right = Math.Min(width - 1, right + 2);
                for (int x = left; x <= right; x++) {
                    int sourceX = cropX + x;
                    if (sourceX >= 1175 && y >= 60 && y < 375) continue;
                    int i = y * inputBits.Stride + sourceX * 4;
                    int o = (y * width + x) * 4;
                    int luminance = (input[i] * 114 + input[i + 1] * 587 + input[i + 2] * 299) / 1000;
                    // Normalize the charcoal backdrop and paper without losing hatch marks.
                    byte tone = (byte)Math.Max(0, Math.Min(255, (luminance - 50) * 255 / 196));
                    output[o] = output[o + 1] = output[o + 2] = tone;
                    output[o + 3] = 255;
                }
            }
            using (var result = new Bitmap(width, height, PixelFormat.Format32bppArgb)) {
                var bits = result.LockBits(new Rectangle(0, 0, width, height),
                                           ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                Marshal.Copy(output, 0, bits.Scan0, output.Length);
                result.UnlockBits(bits);
                result.Save(destination, ImageFormat.Png);
            }
        }
    }
}
'@

[MenuPilotArt]::Prepare($Source, $Destination)
Get-Item -LiteralPath $Destination | Select-Object FullName, Length
