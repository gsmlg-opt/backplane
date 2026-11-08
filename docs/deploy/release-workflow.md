# Release workflow

The main Release workflow builds and publishes Backplane, its Hex packages, and
its Docker image. It does not execute tests, Memory evaluations or benchmarks,
or OpenClaw/Hermes acceptance. Host Agent packages arrive asynchronously on the
same release page after the main release is public. Versions remain unified.

## Workflow ownership

| Workflow | Responsibility |
| --- | --- |
| `ci.yml`, `test.yml`, package CI | Source compilation, regression tests, lint and type checks |
| `memory-test.yml` | Memory migrations/readiness, recall evaluation, benchmark, outage and privacy qualification |
| `memory-plugins.yml` | OpenClaw/Hermes contracts, source lifecycle, real gateway acceptance, packaged plugin verification and logs |
| `release.yml` | Dependency installation, source compilation, immutable release revision, build/package integrity, Hex and Docker publication, final GitHub publication |
| `host-agent-release.yml` | Four-platform Host Agent packaging and additive publication to the existing release |

Memory and plugin workflows run independently on relevant pushes/PRs or manual
dispatch. Release neither invokes them nor waits for them. The existing generic
Test suite may also cover domain unit tests; publication does not rerun that suite.

## Main publication

1. Dispatch Release on `main` with the requested version. The workflow validates
   the selection, then requires only successful `mix deps.get` and `mix compile`
   before preparing the release. It never queries or waits for CI/Test results.
   No tests run in Release.
2. Prepare and push the version-only commit before building. Every following
   build, asset and version tag uses this immutable release commit. The original
   workflow SHA and resulting release SHA are both recorded in the release
   manifest. Compilation applies to the original source before version-only edits.
3. Build shared static assets once, build the two Backplane OTP targets, prepare
   the Docker image, and compile documentation/build the seven Hex packages.
   Runtime and MCP tarballs are prepared outside the umbrella so their published
   dependencies are Hex requirements. These jobs do not run test suites.
4. Validate archive versions/checksums and stage the twelve core assets in a
   **draft** GitHub Release. A matching `core-release-manifest` Actions artifact
   binds the source, version and original workflow run. Host Agent archives and
   test reports are not core assets.
5. Publish Hex dependencies before their consumers. Each package must match its
   preflight artifact. A pre-existing matching version is reused; different
   content fails without overwriting. Package and documentation availability are
   checked before proceeding. Registry API checksums cover the outer archive;
   the package's internal `CHECKSUM` identifies its qualified contents.
6. Restore and publish the previously built Docker image without rebuilding it.
   Verify the immutable version before moving its mutable tag. A conflicting
   image version fails without overwriting it.
7. Verify the core inventory and Docker digest, then publish the draft and mark
   it Latest (prereleases remain prereleases). Explicitly dispatch Host Agent
   publication using the same version and release SHA. This dispatch uses
   `actions: write`; it does not rely on a `release: published` event generated
   by `GITHUB_TOKEN`.

The main release is complete once its core artifacts, Hex publications and
Docker image are available. Host Agent status is displayed separately. Publication
across registries is not transactional; a failure can leave Hex packages or an
image published while GitHub remains a draft.

## Hex staged publishing

Hex.pm enables staged publishing by default for new packages. The setting also
applies to later versions until a full package owner disables it under the
package's **Settings → Staged publishing** page. Changing it requires a signed-in
owner and fresh 2FA verification; `mix hex.publish --yes` and the workflow's API
key cannot disable or bypass it. See [Hex's publishing documentation](https://hex.pm/docs/publish#staged-publishing).

When Hex stages a package or documentation for approval, the helper stops with an
explicit approval message and adds the review link to the Actions job summary.
It does not wait for public-registry propagation or treat staging as publication.
Approve the staged publication on Hex.pm, then use **Re-run failed jobs** on the
original Release run. The helper reuses the approved matching package and docs.

For unattended publication of an existing package, disable its staged publishing
setting separately on Hex.pm. First publication of another new package may need
approval again. The GitHub draft is a separate mechanism and remains private until
all required Hex packages and the Docker image are available.

## Recovery

Use **Re-run failed jobs** on the original Release run. This retains its prepared
SHA, successful build artifacts and manifest. Prepared Hex archives and the Docker
image are retained for 30 and 14 days respectively; the manifest is retained for
90 days. Recovery requires these artifacts to remain available. Release operations
are serialized and a new dispatch never cancels an active publication.

A rerun checks existing asset/package bytes instead of overwriting them. Changed
content requires investigation and a new version. Do not rebuild or repurpose an
already public version. A partial publication remains visible in Actions, and the
GitHub Release remains a draft until core publication finishes.

The qualified Hex recovery verifier accepts the new manifest layout without
requiring Host Agent builds or Memory reports. It retains the original complete
asset/report checks for older releases. The standalone historical Hex recovery
workflow remains a separate operator tool; the main workflow's failed-job retry
is the normal recovery path for new releases.

Host Agent publication can be retried independently with the original version
and SHA. Available platforms are attached to the existing release and its marked
Host Agent status is updated. Its failure does not change the main release's
published state, tag or Latest selection.

These changes require hosted execution to verify runner behavior, registry
publication and cross-workflow dispatch. Local contract/helper tests do not prove
that a release has been published.
