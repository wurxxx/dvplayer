$ErrorActionPreference = "Stop"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:8765/")
$listener.Start()

Add-Content -Path "D:\dvplayer\tmp\fakeapi.log" -Value "listening"

while ($true) {
    $ctx = $listener.GetContext()
    $path = $ctx.Request.Url.AbsolutePath
    $body = ""
    $type = "application/json; charset=utf-8"

    switch -Wildcard ($path) {
        "/api/v2/search/episodes" {
            $body = '{"animes":[{"animeTitle":"test","episodes":[{"episodeId":123,"episodeTitle":"EP1"}]}]}'
        }
        "/api/v2/comment/*" {
            $type = "text/xml; charset=utf-8"
            $body = '<?xml version="1.0" encoding="utf-8"?><i><d p="1.5,1,25,16711680,0,0,0,0">rolling-danmaku</d><d p="2,5,25,255,0,0,0,0">top-danmaku</d><d p="3,4,25,16777215,0,0,0,0">bottom-danmaku</d></i>'
        }
        "/api/v1/subtitles" {
            $body = '{"data":[{"attributes":{"language":"zh-cn","release":"DVPlayer.Test.1080p","movie_name":"test","download_count":42,"ratings":8.5,"hearing_impaired":false,"files":[{"file_id":7,"file_name":"dvplayer-test.srt"}]}}]}'
        }
        "/api/v1/downloads" {
            $body = '{"link":"http://127.0.0.1:8765/files/dvplayer-test.srt","file_name":"dvplayer-test.srt"}'
        }
        "/api/v1/login" {
            $body = '{"token":"test-token"}'
        }
        "/files/*" {
            $type = "text/plain; charset=utf-8"
            $body = "1`r`n00:00:01,000 --> 00:00:04,000`r`nDVPlayer subtitle test`r`n`r`n2`r`n00:00:05,000 --> 00:00:08,000`r`nsecond line`r`n"
        }
        default {
            $body = '{}'
        }
    }

    Add-Content -Path "D:\dvplayer\tmp\fakeapi.log" -Value "$($ctx.Request.HttpMethod) $path"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $ctx.Response.StatusCode = 200
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}
