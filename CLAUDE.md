# CLAUDE.md

Read `README.md` first: it defines the stacks, the conventions and the tooling.

- Run `mise run lint` after any change and leave it green. `mise run fix`
  applies the key order and formatting; review what it changed.
- Pin new images by resolving the multi-arch index digest, e.g.
  `docker buildx imagetools inspect <image>:<tag> --format '{{.Manifest.Digest}}'`,
  not a single-platform digest.
- Unraid exports for conversion go in `_import/` (gitignored). They contain
  real secrets: never copy a secret value into the repo. Replace it with an
  `op://Homelab/<ITEM>/<field>` reference and list the items that need creating
  in 1Password.
- An exception to `scripts/compose-policy.py` goes in its `EXCEPTIONS` map with
  a comment giving the reason. Don't weaken a rule to make one service pass.
