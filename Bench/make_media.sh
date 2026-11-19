#!/bin/zsh
# Builds the benchmark/test clips into Bench/media from the user's source files + synthetic sources.
set -u
cd "${0:a:h}/media"
MP4SRC="${MP4SRC:?set MP4SRC to a long 1080p H.264 MP4 (e.g. a stream VOD)}"
MKVSRC="${MKVSRC:?set MKVSRC to a 4K HDR10 HEVC Blu-ray remux MKV (DTS-HD, PGS)}"
FF=(ffmpeg -hide_banner -loglevel error -y)

cat > subs_en.srt <<'SRT'
1
00:00:01,000 --> 00:00:04,000
Regular English subtitle (should be HIDDEN by default)

2
00:00:05,000 --> 00:00:09,000
Second regular line

SRT
cat > subs_forced.srt <<'SRT'
1
00:00:02,000 --> 00:00:06,000
FORCED subtitle (should SHOW by default)

2
00:00:10,000 --> 00:00:14,000
Forced line two

SRT

# 4K HDR10 HEVC, identical content in MP4 and MKV (AAC audio so every engine can play sound)
[[ -f hevc4k_hdr.mp4 ]] || $FF -ss 300 -t 120 -i "$MKVSRC" -map 0:v:0 -map 0:a:0 -map_chapters -1 -c:v copy -tag:v hvc1 -c:a aac -b:a 256k -ac 2 hevc4k_hdr.mp4
[[ -f hevc4k_hdr.mkv ]] || $FF -i hevc4k_hdr.mp4 -map 0:v -map 0:a -map_chapters -1 -c copy hevc4k_hdr.mkv
# 1080p H.264 with subtitle tracks (one forced)
[[ -f h264_1080p.mp4 ]] || $FF -ss 600 -t 120 -i "$MP4SRC" -map 0:v:0 -map 0:a:0 -map_chapters -1 -c copy h264_1080p.mp4
[[ -f h264_1080p_subs.mkv ]] || $FF -i h264_1080p.mp4 -i subs_en.srt -i subs_forced.srt -map 0:v -map 0:a -map 1 -map 2 -c:v copy -c:a copy -c:s srt \
   -metadata:s:s:0 language=eng -metadata:s:s:0 title=English -metadata:s:s:1 language=eng -metadata:s:s:1 title="English (Forced)" -disposition:s:0 0 -disposition:s:1 forced h264_1080p_subs.mkv
[[ -f h264_1080p_subs.mp4 ]] || $FF -i h264_1080p.mp4 -i subs_en.srt -i subs_forced.srt -map 0:v -map 0:a -map 1 -map 2 -c:v copy -c:a copy -c:s mov_text \
   -metadata:s:s:0 language=eng -metadata:s:s:1 language=eng -disposition:s:0 0 -disposition:s:1 forced h264_1080p_subs.mp4
# Cadence test clips (every frame differs → on-screen hold pattern must be a strict 2,3,2,3; see cadence.swift)
[[ -f cadence_23976.mkv ]] || $FF -f lavfi -i "testsrc2=size=1920x1080:rate=24000/1001" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 90 -c:v hevc_videotoolbox -b:v 8M -tag:v hvc1 -c:a aac -b:a 128k -shortest cadence_23976.mkv
[[ -f cadence_24.mkv ]] || $FF -f lavfi -i "testsrc2=size=1920x1080:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 60 -c:v hevc_videotoolbox -b:v 8M -tag:v hvc1 -c:a aac -b:a 128k -shortest cadence_24.mkv
# Codec coverage clips (synthetic, 20s)
SRC=(-f lavfi -i testsrc2=size=1920x1080:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20)
[[ -f vp9_1080p.webm ]] || $FF $SRC -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 4M -c:a libopus vp9_1080p.webm
[[ -f av1_1080p.mkv ]]  || $FF $SRC -c:v libsvtav1 -preset 10 -crf 35 -c:a libopus av1_1080p.mkv
[[ -f h264_ac3.mkv ]]   || $FF $SRC -c:v h264_videotoolbox -b:v 6M -c:a ac3 -ac 2 h264_ac3.mkv
[[ -f h264_eac3.mkv ]]  || $FF $SRC -c:v h264_videotoolbox -b:v 6M -c:a eac3 h264_eac3.mkv
[[ -f hevc_flac.mkv ]]  || $FF $SRC -c:v hevc_videotoolbox -tag:v hvc1 -b:v 6M -c:a flac hevc_flac.mkv
[[ -f h264_mp3.mkv ]]   || $FF $SRC -c:v h264_videotoolbox -b:v 6M -c:a libmp3lame h264_mp3.mkv
[[ -f h264_dts.mkv ]]   || $FF $SRC -c:v h264_videotoolbox -b:v 6M -c:a dca -strict -2 -ac 2 h264_dts.mkv
[[ -f prores_pcm.mov ]] || $FF $SRC -c:v prores_videotoolbox -profile:v 2 -c:a pcm_s16le prores_pcm.mov
[[ -f mpeg2.ts ]]       || $FF $SRC -c:v mpeg2video -b:v 8M -c:a mp2 mpeg2.ts
[[ -f h264_annexb.ts ]] || $FF $SRC -c:v h264_videotoolbox -b:v 6M -c:a aac h264_annexb.ts
ls -la
# Image-subtitle clips (PGS from the remux, and the same converted to VobSub), marked forced so they auto-show
[[ -f pgs_4k.mkv ]] || $FF -ss 120 -t 60 -i "$MKVSRC" -map 0:v:0 -map 0:a:0 -map 0:s:1 -c copy -disposition:s:0 forced pgs_4k.mkv
[[ -f vobsub_4k.mkv ]] || $FF -i pgs_4k.mkv -map 0:v -map 0:a -map 0:s -c:v copy -c:a copy -c:s dvdsub -disposition:s:0 forced vobsub_4k.mkv
# Letterboxed 2.39:1 picture inside a 16:9 frame (auto-crop test)
[[ -f letterbox_239.mkv ]] || $FF -ss 30 -t 30 -i h264_1080p.mp4 -vf "scale=1920:804,pad=1920:1080:0:138:black" -c:v h264_videotoolbox -b:v 8M -c:a copy letterbox_239.mkv
