# Play the HDR10+ sample through gpu-next and capture the metadata handling log.
# Pure ASCII (PowerShell 5.1 ANSI parsing).

$mpv = "D:\dvplayer\mpv\mpv.com"
$log = "D:\dvplayer\out\hdr10plus.log"
$file = "D:\dvplayer\samples\uhd-4k60-hdr10plus.mp4"

& $mpv --no-config --vo=gpu-next --hwdec=auto-safe --no-audio --frames=120 --msg-level=all=info,vo/gpu-next=debug,vd=debug $file *> $log
"exit=$LASTEXITCODE"
