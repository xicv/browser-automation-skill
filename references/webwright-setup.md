# Setting up Webwright for `browser-delegate`

`browser-delegate` (see `browser-delegate-cheatsheet.md`) offloads a whole multi-step web task onto a **secondary LLM** by driving **microsoft/Webwright** (MIT) out-of-process, so the agent loop runs on your GLM budget instead of Claude Code's context.

You only need this if you want delegation. The skill works fully without it — delegation defaults to `off`.

## Prerequisites
- Python 3.10+ and `git`
- A GLM / Z.AI API key (or any Anthropic-compatible key)
- ~500 MB disk (Playwright Chromium + Firefox)

## 1. Clone + install
```bash
cd ~/tools                 # any dir; the verb looks for ~/tools/Webwright by default
git clone https://github.com/microsoft/Webwright.git
cd Webwright
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
playwright install chromium firefox    # Webwright's final-run step uses Firefox
```
Installed elsewhere? Point the verb at it: `export BROWSER_SKILL_WEBWRIGHT_DIR=/path/to/Webwright`.

## 2. Wire the model backend to GLM
Edit `src/webwright/config/model_claude.yaml` so the Anthropic backend talks to GLM's Anthropic-compatible endpoint:
```yaml
model:
  model_class: anthropic
  model_name: glm-5.1
  anthropic_endpoint: https://api.z.ai/api/anthropic/v1/messages   # intl
  # CN region:        https://open.bigmodel.cn/api/anthropic/v1/messages
  anthropic_version: "2023-06-01"
  max_output_tokens: 16000     # override base.yaml's 4000 for large extractions
```
To use real Anthropic instead: set `model_name: claude-opus-4-7` and `anthropic_endpoint: https://api.anthropic.com/v1/messages`, then use an Anthropic key in step 3.

> Base URL lives **here** (`anthropic_endpoint`), not in an env var — Webwright ignores `ANTHROPIC_BASE_URL`.

## 3. Add your key (global .env, off-argv)
Webwright loads a global `.env` from its platform config dir:
- macOS: `~/Library/Application Support/webwright/.env`
- Linux: `~/.config/webwright/.env`

```bash
ENV="$(python3 -c 'from platformdirs import user_config_dir;import os;print(os.path.join(user_config_dir("webwright"),".env"))')"
mkdir -p "$(dirname "$ENV")"
printf 'ANTHROPIC_API_KEY=%s\n' 'YOUR_GLM_KEY' > "$ENV"
chmod 600 "$ENV"
```
The key never goes on argv and never enters the repo.

## 4. Smoke test
```bash
# Does the skill see the install?
bash scripts/browser-delegate.sh config get        # expect available:true

# Real no-auth task (GLM drives the loop):
bash scripts/browser-delegate.sh \
  --task "Return the top 3 Hacker News story titles as JSON" \
  --start-url https://news.ycombinator.com --task-id smoke
```
Expect a `delegate_result` line + a summary carrying `offloaded_*` token counts. Those tokens are billed to your GLM key, not Claude Code.

## 5. Opt in
Delegation is `off` by default. Turn it on for suitable tasks:
```bash
bash scripts/browser-delegate.sh config set --mode ask    # propose + confirm each time
bash scripts/browser-delegate.sh config set --mode auto   # default to it silently
```
See the **Delegation policy** section in `SKILL.md` for how Claude decides what's "suitable".

## Security / limits (phase 1)
- **No-auth only.** A credentialed `--site` is refused — Webwright persists screenshots + logs in plaintext, so don't run logged-in tasks until the credential bridge ships. Keep tasks to public pages.
- **Privacy canary.** The delegated trajectory is scanned before any result is surfaced; a sentinel hit withholds the result.
- **Rotate leaked keys.** If a key ever lands in a transcript or log, revoke it immediately.

## Troubleshooting
| Symptom | Cause / fix |
|---|---|
| `config get` shows `available:false` | Webwright dir or `.venv` missing — redo step 1, or set `BROWSER_SKILL_WEBWRIGHT_DIR` |
| HTTP 401 from the backend | GLM rejected `x-api-key` (the header Webwright sends). Patch `_request_headers()` in `src/webwright/models/anthropic_model.py` to `Authorization: Bearer`, or recheck the key |
| `max_tokens` / output-length error | lower `max_output_tokens` in `model_claude.yaml` |
| task seems to hang | it's a real browser loop — be patient or narrow the task; inspect the workspace under `$BROWSER_SKILL_HOME/delegate/<task-id>*/` |

## See also
- `references/browser-delegate-cheatsheet.md` — verb usage
- `docs/superpowers/specs/2026-05-29-phase-15-webwright-delegate-adapter.md` — design + roadmap (credential bridge, doctor/cleanup)
- Webwright: https://github.com/microsoft/Webwright
