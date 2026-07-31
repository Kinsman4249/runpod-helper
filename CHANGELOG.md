# Changelog

## Change history

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
