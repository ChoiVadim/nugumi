# Social video downloader profile

> **Superseded.** This profile no longer exists. It was a hardcoded exception
> to a validator that could not install packages or reach the network, and it
> was removed once candidates started being validated by the same `uv` that
> runs a saved tool. A video downloader is now an ordinary Python candidate
> with `yt-dlp` in its PEP 723 header, like any other dependency. Kept for the
> record of why the exception existed.

## Goal

When a user asks Nugumi to download one Instagram, TikTok, or YouTube video,
the Pi builder must produce a Python candidate, test it, and show the normal
Save action instead of returning `UNSUPPORTED`.

## V1 boundary

- Keep prompt and closed native tools unchanged.
- Add one Python dependency profile:
  `yt-dlp==2026.3.17`.
- Do not allow arbitrary packages, package URLs, VCS dependencies, local paths,
  custom indexes, or subprocess-based downloaders.
- Download exactly one item. The generated script must set `noplaylist`.
- Prefer a directly downloadable MP4 and do not require ffmpeg in this profile.
- The saved tool still requires the existing explicit user run approval.

## Validation

- Package the pinned yt-dlp wheel with the sandbox worker.
- Keep the worker's raw network access disabled.
- For the reserved validation URL
  `https://nugumi.invalid/fixture/video.mp4`, substitute a host-owned local MP4.
- Run the real generated script with the real pinned yt-dlp package.
- Require the expected stdout and at least one non-empty regular output file
  for a candidate whose output is `files`.
- Keep Python isolated with `-I -S`; add only the selected bundled profile to
  `sys.path`.
- The source, dependency header, runtime version, and policy version remain
  covered by the existing candidate fingerprint.

## Agent contract

- A network downloader is no longer a general `UNSUPPORTED` case.
- The model must use the exact pinned dependency, set `declaresNetwork: true`,
  and include the reserved fixture.
- A highlighted URL uses `selection` plus the `selection` trigger. A copied URL
  uses `clipboardURL` plus the `link` trigger.
- Other third-party dependency or subprocess requests remain unsupported.
- Validation failures go back through the existing Pi repair loop.

## Acceptance

1. A candidate with an unpinned or unknown dependency is rejected.
2. A downloader that only prints success but creates no file is rejected.
3. A correct candidate imports pinned yt-dlp, downloads the local media fixture,
   produces a non-empty file, and is attested.
4. The Pi conversation reaches `candidateReady` and shows Save.
5. Nothing is persisted until the user presses Save.
