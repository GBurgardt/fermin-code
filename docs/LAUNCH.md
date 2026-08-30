# Communication options

This file is **not** a roadmap or a publishing schedule. It records how the
current source release can be described if the owner chooses to announce it.
No X, Hacker News, or Product Hunt post is promised here.

## Current publication

The public repository and `v0.1.0` release already exist at:

<https://github.com/GBurgardt/fermin-code>

Confirmed:

- the repository is anonymously readable;
- Rust, macOS, and iOS CI passes;
- secret scanning and push protection are enabled;
- private vulnerability reporting is enabled;
- public images contain neutral demonstration content; and
- the repository documents its single-user and self-hosting limits.

Not confirmed:

- a new user has not completed the full guide on a clean third Mac.

That missing check matters. Do not describe the setup as one-click or turnkey.

## X is the simplest first announcement

X fits the current release because one short post can tell the personal story
and link directly to the source.

Draft:

> I open-sourced Fermín Code.
>
> It lets me operate Codex on my own Mac from an iPhone or another Mac. Codex
> stays the agent harness; Fermín adds the durable relay, remote routing,
> reconnect/replay, and native clients.
>
> This is the source I use: Rust relay and engine, macOS, and iOS. The current
> self-hosting limits are documented plainly.
>
> https://github.com/GBurgardt/fermin-code

Optional technical follow-up:

> The useful part is not another chat UI. Fermín saves commands before
> acknowledgement, deduplicates retries, resumes SSE from a cursor, fences
> stale engines, and keeps Codex App Server local to the Mac.

## Show HN requires a human-written post

The [Hacker News guidelines](https://news.ycombinator.com/newsguidelines.html)
say not to post generated or AI-edited text. The owner must write the final
submission in his own words.

A factual post can cover:

- the personal problem Fermín solves;
- what the repository runs today;
- why Codex is the harness and the relay is the remote layer;
- command durability, replay, fencing, offline queueing, and host routing;
- the current single-user limits; and
- the specific technical feedback being requested.

Use a plain `Show HN:` title, link to the repository, and do not ask for
upvotes or coordinated comments. A clean-machine self-host test would provide
stronger evidence before choosing this channel; it is not scheduled by this
document.

## Product Hunt does not match the current release

Product Hunt's official [posting guide](https://help.producthunt.com/en/articles/479557-how-to-post-a-product)
asks for a product URL, short description, gallery, and other launch material;
it also supports a demo. Fermín `v0.1` is a developer source release without a
hosted service or guided installer.

Pragmatic decision: **skip Product Hunt for the current release**. Re-evaluate
only if the actual product becomes easy to install and demonstrate. That is a
condition, not a commitment to build or launch anything.

If a future product qualifies, the accurate copy would be:

```text
Your Mac, operated by Codex from any of your devices
```

```text
Fermín Code connects an iPhone or Mac to a personal Codex host through a
durable relay without exposing Codex App Server directly to the internet.
```

Never claim zero configuration, guaranteed wake, multi-user isolation,
end-to-end encryption, or hosted availability unless the running product can
prove those capabilities.
