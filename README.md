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

**If your `#{ }#` tokens only reference non-secret variables** (a plain
`variables:` block, a non-secret variable group entry, a queue-time
variable, etc.), none of this applies to you — those are already present
in the environment automatically, so `replace-tokens.sh` picks them up
with no `env:` mapping and no `secretVariables` entry needed. The mapping
below is only required for variables Azure DevOps has marked **secret**.

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

### Injecting other env vars (e.g. `System.AccessToken`)

Some values aren't pipeline variables at all — `System.AccessToken` is a
predefined variable that Azure Pipelines withholds from script steps the
same way it withholds secrets. Since the template owns its step's `env:`
block, use `extraEnv` to inject anything like this under whatever name you
want your token to resolve against:

```yaml
- template: replace-tokens.yml
  parameters:
    targetFiles: '**/*.tf'
    extraEnv:
      ACCESSTOKEN: $(System.AccessToken)
```

`#{AccessToken}#` in a target file then resolves to that value.

## Example: a reusable Terraform plan job

[`examples/plan.template.yaml`](examples/plan.template.yaml) is a job
template pulling AzureKeyVault@2 and `replace-tokens.yml` together: it takes
a list of `{ keyVaultName, serviceConnectionName, keyVaultSecrets }` entries,
runs one `AzureKeyVault@2` task per entry, and flattens every entry's
comma-separated `keyVaultSecrets` (the same string passed as `SecretsFilter`)
into `replace-tokens.yml`'s `secretVariables` — one list of secret names to
maintain instead of two. It also demonstrates guarding both the
`AzureKeyVault@2` loop and the `secretVariables` block with
`${{ if parameters.secrets }}`, so a caller that passes no secrets at all
doesn't trip either an unnecessary Key Vault call or a `null` value landing
where `replace-tokens.yml` expects a list (see the file for why that
matters). Validated end-to-end against a real Azure Pipelines agent — see
[Related repositories](#related-repositories) below.

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
| `secretVariables` | object (list) | `[]` | Names of **secret** pipeline variables referenced by `#{ }#` tokens, so they can be explicitly mapped into the step's environment. Non-secret variables are already auto-exposed by Azure Pipelines and don't need to be listed here. |
| `extraEnv` | object (map) | `{}` | Arbitrary extra `env:` entries to inject into the step, keyed by the env var name you want a token to resolve against. For values that aren't plain pipeline variables at all — e.g. `System.AccessToken`, which Azure Pipelines withholds from script steps by default. |

## Related repositories

- **[cdalar/replace-tokens](https://github.com/cdalar/replace-tokens)**
  (GitHub, public) — this repo. Source of truth for `replace-tokens.sh`,
  `replace-tokens.yml`, the test suite, and examples.
- **`dev.azure.com/cdalar/test/_git/replace-tokens-test`** (Azure DevOps,
  private) — a companion sandbox repo used to validate changes against a
  real Azure Pipelines agent before they land here: color output actually
  rendering in the ADO log viewer, `#{ }#` tokens backed by pipeline
  variables whose raw env var name isn't a valid bash identifier (e.g. one
  containing a hyphen), `extraEnv`/`System.AccessToken`, and the
  `examples/plan.template.yaml` job template's guarded, flattened
  `secretVariables` construction — things a local bash test suite can
  exercise the logic of, but can't confirm actually behave a given way on
  ADO's own YAML template engine and hosted agents.

## Testing

```
./tests/test_replace-tokens.sh
```

A pure-bash test suite (no framework, no dependencies) covering token
substitution, variable name normalization, missing/empty variables,
multi-file globs, excluded directories, and edge cases like files with no
trailing newline. Runs in CI via GitHub Actions on every push to `main`
and every pull request (`.github/workflows/tests.yml`).
