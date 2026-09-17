# Raw captures

Stream captures and probe output backing findings [P1]–[P7] in `../research.md`.

Reproduce with the probes one directory up:

```bash
uv run ../session_citation_probe.py      # [P1] citations reach the host only as stream deltas
uv run ../capability_probes.py           # [P5]-[P7] structured output, location types, schema limits
```

## These files are sanitized

Two substitutions were applied before committing. Neither touches a value any finding rests on:

- Absolute home paths replaced with `~`.
- The `system/init` event's `agents`, `plugins`, `skills`, `slash_commands`, `tools` and
  `mcp_servers` arrays replaced with an entry count. Those enumerate the capturing machine's
  personal setup and are evidence for nothing here.

Everything the research cites is untouched, including every `citations_delta` frame, the
`char_location` offsets (53/105 for the NFC document, 57/109 for the NFD one), and the
`system/init` fields the findings actually use — `model`, `claude_code_version`, `apiKeySource`,
`permissionMode`.
