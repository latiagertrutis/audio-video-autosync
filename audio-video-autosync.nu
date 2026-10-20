#!/usr/bin/env nu

# Match external .wav audio recordings to .mp4 camera videos and produce
# output folders with aligned/substituted audio.
#
# Dependencies: ffmpeg, audio-offset-finder (pip install audio-offset-finder)
#
# For each matched pair the output folder contains:
#   - original_video.mp4        — the original camera recording (copied)
#   - original_external.wav     — the full external recorder file (copied)
#   - cropped_external.wav      — external recording trimmed to the video's time-span
#   - final_video.mp4           — video with the external audio replacing the camera mic
def main [
    --input (-i): string   # Input directory containing .wav and .mp4 files
    --output (-o): string  # Output directory for results
    --score-threshold (-s): float = 10.0  # Minimum standard score to consider a match (default: 10)
    --trim (-t): int = 0  # Only use the first N seconds of each file for matching (0 = use full files)
] {
    # ── Validate arguments ──────────────────────────────────────────────
    let input_dir = if ($input | is-empty) {
        print "Error: --input (-i) is required"
        exit 1
    } else {
        $input | path expand
    }

    let output_dir = if ($output | is-empty) {
        print "Error: --output (-o) is required"
        exit 1
    } else {
        $output | path expand
    }

    if not ($input_dir | path exists) {
        print $"Error: Input directory '($input_dir)' does not exist"
        exit 1
    }

    mkdir $output_dir

    # ── Discover files ──────────────────────────────────────────────────
    let video_files = (glob $"($input_dir)/**/*.{mp4,MP4}")
    let audio_files = (glob $"($input_dir)/**/*.{wav,WAV}")

    if ($video_files | is-empty) {
        print "No .mp4 files found in input directory."
        exit 0
    }
    if ($audio_files | is-empty) {
        print "No .wav files found in input directory."
        exit 0
    }

    print $"Found ($video_files | length) video\(s\) and ($audio_files | length) audio file\(s\)"
    print $"Score threshold: ($score_threshold)"
    print ""

    # ── Create a temporary directory for extracted camera audio ────────
    let tmp_dir = (mktemp -d)

    # ── Phase 1: Extract audio from every .mp4 ──────────────────────────
    print "═══ Phase 1: Extracting audio from video files ═══"

    let extracted_audio = ($video_files | each {|video|
        let stem = ($video | path parse | get stem)
        let extracted = $"($tmp_dir)/($stem)__cam_audio.wav"
        print $"  Extracting audio from ($video | path basename)..."

        (ffmpeg -y -i $video
            -vn              # drop video
            -acodec pcm_s16le
            -ar 44100
            -ac 1
            $extracted
            err> /dev/null)

        { video: $video, extracted: $extracted }
    })

    # ── Phase 2: Match each video's audio against every .wav ────────────
    print ""
    print "═══ Phase 2: Finding audio matches ═══"

    let matches = ($extracted_audio | each {|entry|
        let video = $entry.video
        let cam_audio = $entry.extracted
        let video_name = ($video | path basename)

        print $"  Matching ($video_name) against external recordings..."

        let best = ($audio_files | each {|wav|
            let wav_name = ($wav | path basename)

            # Build the audio-offset-finder command arguments
            let args = if $trim > 0 {
                [--find-offset-of $cam_audio --within $wav --json --trim ($trim | into string)]
            } else {
                [--find-offset-of $cam_audio --within $wav --json]
            }

            print $"    vs ($wav_name)..."

            let result = try {
                audio-offset-finder ...$args | from json
            } catch {
                print $"    ⚠ audio-offset-finder failed for ($wav_name), skipping"
                null
            }

            if ($result != null) {
                let offset = ($result | get offset)
                let std_score = ($result | get standard_score)
                print $"    → offset=($offset)s  score=($std_score)"

                { wav: $wav, offset: $offset, score: $std_score }
            } else {
                null
            }
        } | compact          # remove nulls
          | where score >= $score_threshold
          | sort-by score --reverse
          | first 1)         # take best match only (returns a list)

        if ($best | is-empty) {
            print $"  ✗ No match found for ($video_name)"
            null
        } else {
            let m = ($best | first)
            print $"  ✓ ($video_name) ↔ ($m.wav | path basename)  offset=($m.offset)s  score=($m.score)"
            { video: $video, wav: $m.wav, offset: $m.offset, score: $m.score }
        }
    } | compact)  # remove nulls from unmatched videos

    if ($matches | is-empty) {
        print ""
        print "No matches found. Try lowering --score-threshold."
        rm -rf $tmp_dir
        exit 0
    }

    # ── Phase 3: Produce output for each match ──────────────────────────
    print ""
    print "═══ Phase 3: Producing output files ═══"

    $matches | each {|m|
        let video_stem = ($m.video | path parse | get stem)
        let out = $"($output_dir)/($video_stem)"
        mkdir $out

        print $"  📁 ($video_stem)/"

        # 1) Copy original video
        let orig_video = $"($out)/original_video.mp4"
        cp $m.video $orig_video
        print "     ✓ original_video.mp4"

        # 2) Copy original external recording
        let orig_ext = $"($out)/original_external.wav"
        cp $m.wav $orig_ext
        print "     ✓ original_external.wav"

        # 3) Get video duration so we can crop the external recording
        let duration_str = (ffprobe -v error
            -show_entries "format=duration"
            -of "default=noprint_wrappers=1:nokey=1"
            $m.video
            | str trim)
        let duration = ($duration_str | into float)

        # 4) Crop external audio: start at the offset, duration = video length
        let cropped_ext = $"($out)/cropped_external.wav"
        let offset_val = $m.offset

        # The offset from audio-offset-finder tells us where the camera audio
        # starts inside the external recording.  A positive offset means the
        # camera audio begins that many seconds into the external file.
        (ffmpeg -y -i $m.wav
            -ss ($offset_val | into string)
            -t ($duration | into string)
            -acodec pcm_s16le
            $cropped_ext
            err> /dev/null)
        print "     ✓ cropped_external.wav"

        # 5) Replace the video's audio track with the cropped external audio
        let final_video = $"($out)/final_video.mp4"
        (ffmpeg -y -i $m.video -i $cropped_ext
            -c:v copy           # keep original video codec
            -map "0:v:0"        # take video from original
            -map "1:a:0"        # take audio from cropped external
            -shortest           # end when shorter stream ends
            $final_video
            err> /dev/null)
        print "     ✓ final_video.mp4"
    }

    # ── Cleanup ─────────────────────────────────────────────────────────
    rm -rf $tmp_dir

    print ""
    print $"═══ Done! ($matches | length) video\(s\) processed → ($output_dir) ═══"
}
