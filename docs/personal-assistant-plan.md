# Fritz as a personal assistant

Fritz should help one person keep track of their life, understand their information, and follow through on everyday tasks. Chat is the starting point, but the useful result is an answer grounded in the person's own context or an action they chose. The assistant should work well with a local model and give people clear control over what it can see and do.

## Where Fritz is today

Fritz has persistent conversations, provider and model selection, local model downloads, streaming responses, cancellation, and a separate runtime for each chat. Conversations can be grouped under folders. A folder currently gives capable models direct file and local process access. Fritz does not yet connect to a person's calendar, mail, contacts, notes, or reminders; it has no long-term personal memory or proactive routines. Those are product work, not features to imply in onboarding or documentation today.

## Product principles

- **Useful in daily life.** Start with planning a day, finding information, summarizing it, drafting a response, and remembering an explicit preference.
- **Grounded answers.** Show the source and time for personal information. Make uncertainty visible when a source is missing or stale.
- **Clear control.** Ask before connecting a source or taking an action. Let people inspect, correct, export, and delete retained context, and revoke access at any time.
- **Local where practical.** Keep the existing local-model path, disclose when a remote provider receives content, and minimize what is sent.
- **Quiet by default.** Notifications and recurring routines are opt-in, limited, and easy to stop.
- **Typed decisions where useful.** Let a decision model make narrow judgments, while Fritz's code controls thresholds, permissions, and whether a conversational model should explain the result.

## Decision-model foundation

Keep Decision Models and LLMs as distinct model categories. Jev is a remote Decision Model configured with a Keychain-backed connection; a native local decision backend must use the same typed question and answer contract without pretending that a conversational GGUF's generated text is a calibrated probability. The current runtime and provider setup are described in the [decision-harness guide](decision-harness.md). Add an evaluated local decision model and a concrete personal workflow before enabling automatic pairing in chat. A decision can route work to an LLM, but code owns the routing and any action.

## Roadmap

| Phase | Product work | Done when |
| --- | --- | --- |
| 1. Personal chat foundation | Make conversations the primary navigation; replace folder-first setup with a simple first-chat flow. Keep blank project and chat surfaces free of onboarding copy while leaving New and chat controls accessible. Keep provider choice and local conversational models. | A new user can start and resume a useful conversation without choosing a folder or configuring an action first. |
| 2. Personal context | Add a small, user-controlled profile for preferences and facts; connect one personal source in read-only mode, starting with calendar or notes; provide source attribution, access status, and deletion controls. | Fritz can answer a question using an authorized source, show where the answer came from, and stop using that source after revocation. |
| 3. Helpful actions | Add scoped actions such as creating a reminder or preparing a calendar event or message. Show the exact proposed change and require confirmation before writing or sending. Keep a visible action history. | A user can complete one everyday task from chat and inspect or undo it where the service allows. |
| 4. Follow-through | Add opt-in recurring check-ins and reminders, with notification controls and clear failure states. | Fritz can follow up at the chosen time without duplicating an action or silently continuing after access is lost. |
| 5. Retire folder-based execution | Migrate any useful document access to explicit, scoped personal sources; remove unrestricted folder actions and local process execution from the assistant experience and CLI. Update stored conversation handling and migration guidance. | Personal tasks work without the legacy folder workflow, and no chat can invoke a general local process action. |

## First release slice

Ship phases 1 and a narrow part of 2 before expanding actions: a focused chat, dependable conversation history, a visible choice of local or remote model, a small editable profile, and one read-only personal source. Test with concrete tasks such as “What is on my calendar tomorrow?”, “Summarize these notes,” and “Remember that I prefer morning appointments.” The first two require source attribution; the last requires explicit save and delete controls.

Measure whether people can finish these tasks, whether answers cite the right source, and whether they understand what is stored or sent to a provider. Use task completion and correction rates, not message count, as the primary signal.

## Transition rule

Until phase 5 is complete, describe folder access as a current capability with its real permissions and limits. Do not present it as Fritz's purpose or use it as the default first-run path. The [README](../README.md) should describe what ships now; this plan describes what comes next.
