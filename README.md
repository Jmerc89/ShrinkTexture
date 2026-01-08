SHRINK TEXTURES TOOL (ImageMagick)
=================================
Author: Jesse Mercer (NXT Dev Studios LLC)
Date: 01/08/2026

PURPOSE
-------
This Windows utility recursively downsizes and optionally converts textures inside a folder using ImageMagick.
It is designed to normalize oversized asset packs (e.g. 4K textures) into sane, production-ready sizes while
keeping repositories clean and manageable.

FEATURES
--------
- Recursive scan of a target folder (includes all subfolders)
- Select maximum resolution (longest side)
- Select input file types to process (multi-select + custom extensions)
- Select output file format (optional conversion)
- "Only shrink" behavior (never upscales smaller images)
- Safe overwrite: writes a temporary file first, then replaces the original
- Optional backups (.bak)
- Dry run mode (no files modified)
- Optional logging
- Pixel art scaling mode (nearest-neighbor)
- Can display supported formats on the current machine (magick -list format)
- Automatically skips common engine cache/build folders (Unity / Unreal / tooling)

GETTING THE TOOL
----------------
Clone the repository using Git:

> git clone https://github.com/Jmerc89/ShrinkTexture.git

Or download the repository as a ZIP from GitHub and extract it locally.

INCLUDED FILES
--------------
- ShrinkTextures.cmd  -> Double-click launcher (recommended)
- ShrinkTextures.ps1  -> Main PowerShell script
- README.txt          -> This file

REQUIREMENTS
------------
1) Windows + PowerShell
   - PowerShell 7 recommended.

2) ImageMagick 7 (REQUIRED)
   Download (official site):
   https://imagemagick.org/script/download.php#windows

   During installation, enable:
   - Add application directory to your system PATH   (IMPORTANT)

   Verify installation in PowerShell:
   > magick -version

   If a version is printed, ImageMagick is ready.

HOW TO USE
----------
Option A: Process the folder the script is placed in
1) Copy ShrinkTextures.cmd and ShrinkTextures.ps1 from the cloned repository
   into the folder you want to process.

   Example:
   D:\Project\Assets\SomeAssetPack\Textures\

2) Double-click ShrinkTextures.cmd

3) In the popup, choose:
   - Max size (px)
   - Input file types
   - Optional output format
   - Optional safety features (Dry Run, Backups, Skip Normals, etc.)
   Then click Run.

Option B: Drag & drop a folder onto the launcher
1) Place ShrinkTextures.cmd and ShrinkTextures.ps1 anywhere (e.g. a Tools folder).
2) Drag a target folder onto ShrinkTextures.cmd
3) Choose options and click Run.

WHAT IT DOES (UNDER THE HOOD)
-----------------------------
- Recursively finds selected file types under the target folder
- Skips common engine-generated directories automatically
- Uses ImageMagick with a resize rule similar to:
  
  magick input.png -resize 1024x1024> output.png

  The ">" operator means:
  - Only shrink images larger than the requested size
  - Never upscale smaller images

- If an output format is selected, images are converted accordingly
- Writes a temporary output file first, then replaces the original only if successful

OPTIONS (WHAT THEY MEAN)
------------------------
- Strip metadata:
  Removes embedded metadata to reduce file size.

- Max PNG compression:
  Applies stronger PNG compression (slower, smaller output). PNG only.

- Skip files containing "Normal":
  Useful if you want to avoid resizing normal maps automatically.

- Pixel art mode:
  Uses nearest-neighbor scaling. Recommended only for pixel art.

- Dry run:
  No files are modified; logs what would be processed.

- Backups:
  Creates a single .bak file beside each original for rollback.

- Logging:
  Writes a log file into the target folder (default: ShrinkTextures_log.txt).

SAFETY NOTES (READ THIS)
------------------------
- If Dry Run is OFF, files may be overwritten in place.
  Commit or back up assets before running in a shared repository.

- Normal maps:
  Resizing is generally safe, but aggressive downscaling may cause shading artifacts.

- Source formats (PSD / EXR / HDR):
  Some ImageMagick installs support these formats.
  Overwriting source files may be undesirable — enable intentionally.

TROUBLESHOOTING
---------------
1) "magick not found"
   ImageMagick is not installed or not on PATH.
   Reinstall ImageMagick and enable:
   - Add application directory to your system PATH
   Restart PowerShell and verify with:
   > magick -version

2) Different formats supported on different machines
   ImageMagick format support depends on installed delegates.
   Use the tool option "Show ImageMagick formats" to view supported formats.

LICENSE
-------
This project is open source under the MIT License.
See the LICENSE file for full details.

DEPENDENCIES
------------
This tool depends on ImageMagick, which is licensed under the Apache 2.0 License.
ImageMagick is NOT included with this repository.

Users must install ImageMagick separately from the official website:
https://imagemagick.org

If you use or adapt this tool, a link back to https://nxtdevstudios.com is appreciated.
