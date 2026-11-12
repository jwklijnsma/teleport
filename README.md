# teleport – build & release

Builds [Teleport](https://github.com/gravitational/teleport) from source with GitHub Actions and hosts the results on GitHub:

| Artifact | Where |
|---|---|
| `teleport-<version>-1.x86_64.rpm`, `.deb`, release tarball | GitHub Releases |
| Container image | `ghcr.io/jwklijnsma/teleport:<version>` |
| Helm charts (`teleport-cluster`, `teleport-kube-agent`) | `oci://ghcr.io/jwklijnsma/charts/<chart>` and the release |

## Usage

* **Manual:** Actions → *Release* → *Run workflow*. Pick the Teleport ref (e.g. `v15.5.4`) and tick *publish* to push the image/charts and create the release. Without *publish* it only builds and keeps the files as workflow artifacts.
* **Tag:** push a tag `vX.Y.Z` to this repo; the source ref with the same name is built and published.

The source is taken from `gravitational/teleport` unless the repository variable `TELEPORT_SOURCE_REPOSITORY` (or the *source_repository* input) points somewhere else, for example at this repo once it holds the source.

Optional secrets `RPM_GPG_PRIVATE_KEY` / `RPM_GPG_PASSPHRASE` sign the RPM.

## Files

* `.github/workflows/release.yml` – the workflow
* `ci/setup-toolchain.sh` – installs Go / Node.js / Rust at the versions the source tree asks for (EL8 container)
* `ci/package.sh` – builds the RPM and DEB with fpm
