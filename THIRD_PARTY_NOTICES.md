# Third-party notices

Original reproduction scripts, fixtures, and documentation are covered by the repository's `LICENSE`, except for the upstream-specific files identified below. Upstream components retain their own licenses and copyright notices.

| Component | Pinned source | Files in this repository | License |
| --- | --- | --- | --- |
| Grafana | [`v12.4.1`, `46a02dc12a085445ab105b72fa159248f7d1dc9d`](https://github.com/grafana/grafana/tree/46a02dc12a085445ab105b72fa159248f7d1dc9d) | `patches/grafana.patch`, `tests/grafana/` | AGPL-3.0-only |
| Grafana Operator | [`v5.24.0`, `065a718a1fe83728d08054c299de7f8577e88f79`](https://github.com/grafana/grafana-operator/tree/065a718a1fe83728d08054c299de7f8577e88f79) | `patches/operator.patch`, `tests/operator/` | Apache-2.0 |

Grafana patch context comes from `pkg/api/frontendsettings.go`. Its [license policy](https://github.com/grafana/grafana/blob/46a02dc12a085445ab105b72fa159248f7d1dc9d/LICENSING.md) assigns AGPL-3.0-only to this file; it is outside the listed Apache-2.0 exceptions. The patch changes SQL datasource normalization to use the resolved plugin ID. The accompanying regression tests are additions for that version.

Grafana Operator patch context comes from `controllers/datasource_controller.go`, whose existing notice begins “Copyright 2022” and identifies the Apache License, Version 2.0. The patch changes datasource hashing to serialize the resolved API payload deterministically. The accompanying regression tests are additions for that version.

Full license texts are included in [`LICENSES/AGPL-3.0-only.txt`](LICENSES/AGPL-3.0-only.txt) and [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt). The pinned upstream copies are [Grafana's LICENSE](https://github.com/grafana/grafana/blob/46a02dc12a085445ab105b72fa159248f7d1dc9d/LICENSE) and [Grafana Operator's LICENSE](https://github.com/grafana/grafana-operator/blob/065a718a1fe83728d08054c299de7f8577e88f79/LICENSE).

Build and test commands fetch upstream source, dependencies, and container images separately. Those components are not relicensed by this repository. These are independently proposed patches, not upstream releases or an endorsement by the upstream projects.
