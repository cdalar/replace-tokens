# replace-tokens

A pure-bash, dependency-free drop-in replacement for the
[`qetza.replacetokens-task@6`](https://marketplace.visualstudio.com/items?itemName=qetza.replacetokens)
Azure DevOps task, using its default settings. No Node.js task runtime,
`perl`, `sed`, or `awk` required for the substitution itself — just `bash`.

Two ways to use it:

- **`replace-tokens.sh`** — a standalone script you can call from any
  `bash` step.
- **`replace-tokens.yml`** — an Azure Pipelines step template that wraps
  the same logic and automates mapping secret pipeline variables into the
  step's environment.

## What it does

Scans the target files for `#{VariableName}#` tokens and replaces each one
with the value of the corresponding variable, sourced from environment
variables — the same defaults as the original task:

| Setting | Default behavior |
|---|---|
| Token pattern | `#{ }#` |
| Variable source | Environment variables |
| Variable name → env var mapping | Uppercase, non-alphanumeric characters become `_` (matches how Azure DevOps exposes pipeline/KeyVault variables) |
| `actionOnMissing` | `warn` — logs a warning, does not fail the step |
| `keepToken` | `false` — a missing or empty variable is replaced with an empty string |

Values are never printed to the log, only token/variable names:

- Token replaced with a non-empty value → info line.
- Variable exists but is empty → warning.
- Variable not found at all → warning.

**Note:** matching is done line-by-line, so a token split across a line
break is not recognized. This is the one behavioral difference from the
original task, which scans the whole file.

## Important: secret variables

Azure Pipelines only auto-exposes **non-secret** pipeline variables as
environment variables to plain `script`/`bash` steps. Secret variables —
which is exactly what `AzureKeyVault@N` produces — are **not**
auto-exposed, regardless of naming. You must explicitly map each one in
the calling step's YAML.

### Using `replace-tokens.sh` directly

```yaml
- bash: ./replace-tokens.sh '**/*.tf'
  env:
    APIKEY: $(ApiKey)
    MY_CONNECTION_STRING: $(My.Connection-String)
```

The `env:` key must equal `normalize_key()`'s output for that token name:
uppercase, non-alphanumeric → `_`.

### Using the `replace-tokens.yml` step template

The template automates the above via its `secretVariables` parameter —
prefer this over the standalone script when you can:

```yaml
- template: replace-tokens.yml
  parameters:
    targetFiles: '**/*.tf'
    excludeDirs: '.terraform'
    secretVariables:
      - ApiKey
      - My.Connection-String
```

## Usage (standalone script)

```
replace-tokens.sh '<glob-pattern-1>' ['<glob-pattern-2>' ...]
```

Example:

```
replace-tokens.sh '**/*.tf'
```

Directories named `.terraform` are excluded by default (edit the
`exclude_dirs` array in the script to change this).

## Template parameters (`replace-tokens.yml`)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `targetFiles` | string | `**/*.tf` | Glob pattern(s) of files to process, newline-separated for multiple |
| `excludeDirs` | string | `.terraform` | Comma-separated directory names to skip |
| `secretVariables` | object (list) | `[]` | Pipeline variable names referenced by `#{ }#` tokens that are secret; each is mapped into the step's environment |
