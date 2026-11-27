# Platform Reference Templates

Canonical YAML templates for the Enterprise Agentic AI Platform.
These are the source of truth for documentation, examples, and the future reference UI.

## Structure

```
templates/
  agent/           — What App Teams write
  gateway/         — What Shared Services Teams write
  composition/     — Agent composition patterns
```

## Rules

- Every field must have a comment explaining what it does
- Templates must be valid YAML (not just snippets)
- New manifest types or patterns get added here first, then referenced elsewhere
