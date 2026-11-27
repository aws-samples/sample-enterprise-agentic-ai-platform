# knowledge-bases-team-bu-1

Source repo for the **`kb-team-bu-1-deploy`** CodePipeline (domain: `team-bu-1`).

Each subdirectory that contains a `kb.yaml` is discovered and provisioned as a
Bedrock Knowledge Base (plus its declared data sources, an MCP gateway target,
and a Cedar access policy) by the platform's `kb-deploy` Terraform template.

## Layout

```
<kb-name>/
  kb.yaml            # KB config: name, description, embedding_model,
                     # chunking_strategy.type, sync_schedule (+ optional
                     # retrieval / access / tags)
  data-sources.yaml  # non-empty data_sources[] list (s3 | web_crawl |
                     # confluence | sharepoint | salesforce | custom)
```

## Pipeline

`Source (this repo, main) → Validate → Plan → Apply`

Pushing to `main` triggers the pipeline. The Validate stage schema-checks every
`kb.yaml` / `data-sources.yaml`; Plan/Apply run the `kb-deploy` template.

## Current knowledge bases

- **team-bu-1-docs** — baseline KB with a platform-managed S3 data source bucket.
