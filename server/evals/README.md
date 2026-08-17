# Command routing evals

`cases.jsonl` covers Korean built-in commands, conversational fallbacks, ambiguous
requests, unsupported hotel adjustments, and tool drafts for connected devices. Hotel
adjustments remain conversational unless a matching hotel-scoped device capability is
connected. The runner exercises the real
route, draft approval, distinct first-execution confirmation, and reuse functions while
allowing the Needle and GPT stages to be replaced with deterministic fixtures for CI.

Run the deterministic contract suite with:

```bash
mise run server:eval
```

To probe the installed Needle base model as well, set `ADSPACE_EVAL_LIVE_NEEDLE=1`.
Live results are diagnostic because the base model's confidence is not calibrated
for Korean and low-confidence results are expected to fall back to GPT.

Results are written to `server/evals/results/latest.json` and the command exits
non-zero when a contractual case fails.
