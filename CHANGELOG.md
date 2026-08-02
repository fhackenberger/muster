# Changelog

Notable changes. The format is loosely [Keep a Changelog](https://keepachangelog.com/); versions are
git tags, and the published images (`muster`, `muster-hub-base`, `muster-broker`) carry the same tag.

Why versions matter here: `common-setup.sh` deliberately resolves the *latest* node, claude and tuicr
at build time, so a commit does not identify an artifact. A tag does — see
`docs/adr/0001-image-builds.md`.

Every commit on `master` is published as well, under its `git describe` name (`0.1.1-7-gabc1234`) and a
moving `dev`, so running an unreleased change never requires cutting a release for it. Those are not
releases and are not listed here.

## [0.1.0] — 2026-08-02

### Added
- First public release. Extracted from the private Ansible repository it grew up in, with its history.
