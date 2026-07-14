# Releasing Flightdeck

Release references are a single consistency boundary: nested reusable
workflows, the template caller, Terraform module source, release marker, and
current-release documentation must all identify the same tag. The inventory in
`scripts/release_consistency.py` is authoritative; do not maintain a parallel
grep checklist.

## Prepare

Start from a clean release branch based on `main`, then choose the next semantic
version. For example:

```sh
TAG=vX.Y.Z
git switch main
git pull --ff-only origin main
git switch -c "codex/release-${TAG}"
make prepare-release TAG="$TAG"
make check-release TAG="$TAG"
make validate
make test
```

`prepare-release` updates every inventoried reference and immediately verifies
the result. Review the diff, write release notes from the merged changes since
the preceding tag, and commit the coherent release candidate. Do not retarget
an existing tag: app upgrades record the immutable commit to which the tag
resolved and abort if that mapping changes during download.

Open and merge the release-preparation PR through the normal review process.
Its description is the draft for the release notes: summarize the changes,
security and operational implications, tests, adoption steps, rollback, and
known limitations.

## Publish

After the release-preparation PR is merged, tag the exact updated `main` commit
and let GitHub generate notes from the previous release:

```sh
TAG=vX.Y.Z
PREVIOUS_TAG=vA.B.C
git switch main
git pull --ff-only origin main
make check-release TAG="$TAG"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" && {
  echo "error: $TAG already exists; choose a new version and repeat release prep"
  exit 1
}
git tag -a "$TAG" "$(git rev-parse HEAD)" -m "Flightdeck $TAG"
git push origin "refs/tags/$TAG"
gh release create "$TAG" \
  --repo rpuffe/flightdeck \
  --verify-tag \
  --title "$TAG" \
  --generate-notes \
  --notes-start-tag "$PREVIOUS_TAG"
```

`make check-release` proves the published template and nested references are
self-consistent. Review the generated notes in GitHub immediately. If the tag
push succeeds but `gh release create` fails, fix the release metadata or
authentication problem and rerun only that same `gh release create` command.
Do not move, force-push, or delete a published tag. If the remote-tag check or
push reports a conflict, choose a new patch version, rerun release preparation,
and publish that version instead.

## Rollback

Publishing does not apply Terraform or change an application deployment. Apps
adopt deliberately, so an app can roll back with `make upgrade TAG=<prior-tag>`,
review the diff and provenance, run preflight, and commit the downgrade. If a
platform release itself is defective, revert it on a new branch and publish a
new patch release; never retarget the defective tag. The immutable tag commit
record in `.flightdeck-provenance` keeps both adoption and rollback inspectable.

Application repositories remain on their prior pin until their owner runs
`make upgrade TAG=vX.Y.Z`, reviews the recorded `.flightdeck-provenance`, runs
preflight, and commits the resulting app change.
