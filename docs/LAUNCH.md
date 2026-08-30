# Pragmatic launch plan

## Order

1. **GitHub and `v0.1.0` first.** The repository is the product proof: source,
   architecture, limitations, setup, tests, and screenshots must all exist at
   the same public URL.
2. **X/Twitter on the same day.** Tell the personal story, state the product
   boundary in one sentence, and link directly to GitHub. The goal is useful
   feedback from developers, not a large launch ceremony.
3. **Show HN after a clean-machine self-host test.** Show HN works best when a
   reader can run the thing, inspect the implementation, and ask technical
   questions. Do not post a roadmap-only project.
4. **Product Hunt later.** Wait for a signed Host app, guided pairing, and a
   short demo. Product Hunt is a distribution event for a more approachable
   product, not the best place to debug developer onboarding.

## X/Twitter draft

> I open-sourced Fermín Code.
>
> It lets me operate Codex on my own Mac from an iPhone or another Mac. Codex
> stays the agent harness; Fermín adds the durable relay, remote routing,
> reconnect/replay, and native clients.
>
> This is the real source I use—Rust engine/relay, macOS, and iOS—with the
> current self-hosting limits documented plainly.
>
> https://github.com/GBurgardt/fermin-code

Optional follow-up:

> The interesting part is not another chat UI. A command is persisted before
> acknowledgement, retries are idempotent, SSE resumes from a cursor, stale
> engines are fenced, and Codex App Server stays local to the Mac.

## Show HN preparation

The current [Hacker News guidelines](https://news.ycombinator.com/newsguidelines.html)
ask authors not to post generated or AI-edited text.
German should therefore write the final submission himself, in his own words,
after completing the clean-machine self-host test. Do not paste generated copy
from this repository into HN.

The hand-written post should stay factual and cover:

- the personal problem that led to Fermín Code;
- what a reader can run from this repository today;
- why the relay is the product boundary and Codex remains the harness;
- the durable-command, replay, fencing, offline-queue, and host-routing work;
- the developer-oriented single-user limits of `v0.1`; and
- the specific technical feedback German wants from the community.

Use a plain title beginning with `Show HN:` and link directly to the runnable
repository. Avoid marketing language and do not ask anyone to upvote or seed
comments.

## Product Hunt position for later

Product Hunt's current posting flow expects a live product presentation with a
gallery, product description, and preferably a demo. Prepare that launch only
after the signed Host app and guided pairing make the project approachable;
use the official [posting guide](https://help.producthunt.com/en/articles/479557-how-to-post-a-product)
as the final checklist.

Tagline:

```text
Your Mac, operated by Codex from any of your devices
```

One-line description:

```text
Fermín Code connects an iPhone or Mac to a personal Codex host through a
durable, secure relay—without exposing the host directly to the internet.
```

Do not claim zero-configuration, guaranteed wake, multi-user isolation,
end-to-end encryption, or hosted availability until those capabilities ship.

## Launch checklist

- [ ] Repository is anonymously readable.
- [ ] `v0.1.0` release points to the tested commit.
- [ ] Secret scanning and push protection are enabled.
- [ ] Private vulnerability reporting is enabled.
- [ ] CI is green on the public repository.
- [ ] A clean machine completes the self-host guide.
- [ ] Screenshots contain no credentials or production endpoints.
- [ ] Issues have labels for `service`, `desktop`, `mobile`, `security`, and
  `documentation`.
- [ ] Social posts link to the repository, not to a private product page.
