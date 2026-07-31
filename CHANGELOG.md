# Changelog

## Change history

### 0.2.0 - Wizard UX and validation enhancements

1. Enhanced PREREQUISITES.md with detailed guidance on datacenter selection tradeoffs (jurisdiction/privacy vs. latency), GPU tier sizing for each model preset (4-bit/8-bit/fp16), and network volume sizing recommendations based on model precision and storage needs. Updated README.md to reference this expanded guidance.
2. Refactored GPU and datacenter selection (`lib/launch.sh`, `lib/wizard.sh`) to use a common menu-driven interface (`select_from_menu()` helper in `lib/common.sh`) with smart filtering: GPU selection now auto-filters by VRAM requirement and datacenter availability, preventing invalid picks instead of warning after the fact.
3. Enhanced wizard step-by-step guidance (particularly GitHub App and Cloudflare Tunnel setup) with significantly more detailed substeps, field-by-field instructions, and links to configuration checks, reducing ambiguity and setup errors on first run.

### 0.1.0 - Initial release

1. Added five core lifecycle scripts for pod setup and runtime: `startup.sh`
   (pod creation and GitHub auth setup), `onstart.sh` (pod boot tasks
   including Cloudflare Tunnel and idle watchdog startup), `idle-watchdog.sh`
   (idle session detection and pod lifecycle management), and
   `safety-commit.sh` (emergency commit to a safety branch before shutdown).
2. Added setup wizard infrastructure (`lib/wizard.sh`, with `lib/common.sh`
   and `lib/launch.sh` helpers) to guide first-time users through RunPod API
   key setup, SSH key registration, model volume creation, and GitHub App
   integration - all steps required before the first pod launch.
3. Fixed deprecated `runpodctl config --apiKey` call in wizard by switching
   to environment variable export (`RUNPOD_API_KEY`), matching the current
   CLI's documented configuration method.

### Initial scaffold (round one)

1. Added the community-health files (README, CONTRIBUTING, CODE_OF_CONDUCT,
   SECURITY, issue templates, pull request template) copied from the
   Kinsman4249/.github-private canonical templates and filled in for this
   project.
2. Added the tag-triggered release workflow copied from the same
   template, configured for the shell-script build path with the OS
   matrix trimmed to ubuntu-latest, since this project ships bash
   scripts with no platform-specific build step.
3. Added PREREQUISITES.md as the itemized list of what needs to exist on
   RunPod, Cloudflare, and GitHub before running startup.sh, and updated
   README.md to point to it instead of embedding the same list, since
   startup.sh's setup wizard (see item below) now handles most of what
   used to require manual setup.
