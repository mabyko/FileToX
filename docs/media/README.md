# FileToX Finder demo assets

- `filetox-demo.mp4`: 20 seconds, 1920×1080, 30 fps, 600 frames, H.264/YUV420p, fast-start MP4, silent.
- `filetox-demo.gif`: 960×540, 10 fps, 200 frames, looping README preview.
- `filetox-demo-poster.png`: JPG drop-target frame for video links and sharing.

## What was recorded

The actual English Release app runs in the menu bar with its main window closed. In Finder, holding Option (⌥) and dragging `Landscape.png` opens the radial menu. Dropping onto JPG converts the file; `Landscape.jpg` appears beside the original. The first two seconds reuse the actual result as a still frame, then the video shows the gesture from the beginning.

The original file’s SHA-256 was unchanged after conversion, and the JPG output decoded successfully. The single-file radial title was corrected to “1 file” before the final take; the Release build and seven localization tests passed. The sample landscape is an original generated graphic. The backdrop, English caption pills, Option keycap and camera zooms are production graphics; the Finder and FileToX interfaces and conversion results are direct recordings.

Claude helped research references, create the storyboard and AppKit overlay cards, and review the final footage. Capture used macOS `screencapture`; editing used the installed FFmpeg. Raw takes, overlay sources and temporary scripts are under the Git-excluded `build/promo2/` directory. The earlier Home demo’s scratch files remain in `build/promo/`.

## Scene plan

| Time | Actual footage and edit | Caption |
| --- | --- | --- |
| 0–2 s | Result-first still; eased zoom out | PNG to JPG. No window. |
| 2–4 s | Finder before the drag; FileToX’s main window stays closed | FileToX runs in the menu bar. |
| 4–8 s | Hold Option, grab PNG, open the wheel; zoom toward it, show the pressed keycap | Hold Option and drag. |
| 8–11.5 s | Move to the JPG wedge, pause, then release | Drop on JPG. |
| 11.5–17 s | Actual completion and source/result side by side; ease out | Saved beside the original. |
| 17–20 s | FileToX end card | Hold ⌥ · Drag · Drop |

## Production prompt

```text
Create a 20-second English product demo for FileToX, a Mac-only converter.
Use actual supplied Finder footage with FileToX running in the menu bar
and its main window closed. Show Option (Alt/⌥) held during the drag,
the real radial menu opening, a JPG drop and the actual output beside
its source. Never simulate or retouch the application interface.

Open with two seconds of the actual result. Then show the gesture from
its beginning: 2–4s Finder; 4–8s Option-drag and wheel; 8–11.5s JPG drop;
11.5–17s completion and files; 17–20s FileToX end card.

Use a dark blue backdrop, #3478F6 accent, large SF caption pills,
a pressed Option keycap and eased zooms toward the action. Keep each
caption short and reveal the result caption after the output appears.
Keep the pointer clear of filenames and the JPG label readable.
Avoid private paths, personal menu-bar items and unsupported claims.

Export a silent 1920×1080, 30fps H.264 fast-start MP4 and a 960×540,
10fps looping GIF. Keep both below 10 MB. Check frame counts, playback,
caption readability, original-file integrity and output decoding.
```

## References checked on 2026-10-11

- [Remotion’s X announcement](https://x.com/Remotion/status/2013626968386765291): its public post describes making an animation with Claude Code and Agent Skills. The browser loaded the post title but timed out reading its body; the text and author were verified through X’s public syndication response.
- [Harnoor Singh on Threads](https://www.threads.com/@iharnoor/post/DMibEF6gbxz): the public post preview shares a brief Claude Code/Remotion infographic prompt. It supports giving a concrete visual task rather than requesting a vague promotional video.
- [@meta.ai on Threads](https://www.threads.com/@meta.ai/post/DePa8ALgYZF/): the public preview specifies a 15-second motion reel, resolution, frame rate and numbered sequences. We adopted explicit scene constraints; this reference does not establish the account’s affiliation.
- [Launch Video on X prompt](https://www.remotion.dev/prompts/launch-video-on-x): creator @ghumare64 gives precise frame counts and animated scene transitions.
- [Presscut product demo prompt](https://www.remotion.dev/prompts/product-demo-for-presscut): creator @Shpigford starts with the demonstration a customer should see.
- [VVTerm promotion prompt](https://www.remotion.dev/prompts/promotion-video-for-vvterm): creator @wiedymi requests a short presentation using the product’s own assets.
- [Every’s product launch video workflow](https://github.com/EveryInc/product-launch-video/blob/main/README.md): early product visibility, readable captions and an outcome-first short demo informed the edit.

These are creative references. Remotion is not a rendering dependency of this project. No third-party footage, music or copied prompt text is included in the exported assets.

## README playback

All three READMEs use a relative GIF preview linked to the MP4, so no hosted URL is required. An inline GitHub player needs a supported uploaded attachment URL; that can replace the link after publication. GitHub recommends H.264 for compatibility. See [GitHub attachment documentation](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files).
