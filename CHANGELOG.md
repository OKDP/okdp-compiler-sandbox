# Changelog

## 1.0.0 (2026-11-18)


### ⚠ BREAKING CHANGES

* **argocd:** one parent per project, okdp-objects registry and namespaced hosts
* **ci:** serve the CI repositories and catalogs over HTTPS
* **bootstrap:** verify chart digests, default-deny namespaces and install approver-policy
* **supply-chain:** pin catalogs by commit and e2e manifests and images by digest
* **s3:** restrict the platform S3 identity to the demo project
* **network:** per-project NetworkPolicies and Pod Security levels
* **tls:** verify Keycloak, OpenBao and Forgejo against the platform CA bundle
* **access:** dedicated Forgejo accounts, the okdp realm and per-project groups
* **check:** let okdp-gitops compile validate the tree and fill the chart cache
* **topology:** split platform, projects and output repositories, compiled by the output's CI
* **secrets:** scope the demo's secrets to its namespace and drop kubernetes-replicator

### Features

* **access:** dedicated Forgejo accounts, the okdp realm and per-project groups ([787e5d9](https://github.com/OKDP/okdp-compiler-sandbox/commit/787e5d999b44610ac7b735eabe70241e294f80e3))
* added conventional commits ([1938d29](https://github.com/OKDP/okdp-compiler-sandbox/commit/1938d29788e4db9faa33bf6e5b678d9408434122))
* **airflow:** add OIDC auth support and harden package configuration ([c32a897](https://github.com/OKDP/okdp-compiler-sandbox/commit/c32a8979c526fc2fdb4af7a417870445d53763d2))
* **argocd:** one parent per project, okdp-objects registry and namespaced hosts ([175a724](https://github.com/OKDP/okdp-compiler-sandbox/commit/175a724e10ac0ecdc81533057aec79b4a477e9f6))
* **bootstrap:** verify chart digests, default-deny namespaces and install approver-policy ([1a48ce4](https://github.com/OKDP/okdp-compiler-sandbox/commit/1a48ce4733e9baeaf92c2b17d5794b250ee8805c))
* **ci:** serve the CI repositories and catalogs over HTTPS ([b278396](https://github.com/OKDP/okdp-compiler-sandbox/commit/b27839693ac44935a307748120a3b00eda4c786e))
* deploy the sandbox from an okdp-compiler layout with Argo CD or Flux ([39da3e1](https://github.com/OKDP/okdp-compiler-sandbox/commit/39da3e17a2e342c2044fe7b50a7590dc18b02c33))
* **network:** per-project NetworkPolicies and Pod Security levels ([c5f01d5](https://github.com/OKDP/okdp-compiler-sandbox/commit/c5f01d5bdfa452237bbf48af17985416e1b52a75))
* render instance objects with the okdp-objects chart ([f27c10a](https://github.com/OKDP/okdp-compiler-sandbox/commit/f27c10a0fd9eb20b5bfeef57c5c0c3122bccf923))
* **supply-chain:** pin catalogs by commit and e2e manifests and images by digest ([f64d30e](https://github.com/OKDP/okdp-compiler-sandbox/commit/f64d30e792e608196eff7cbbfad40e7b3b2fdef1))
* **topology:** split platform, projects and output repositories, compiled by the output's CI ([336f14a](https://github.com/OKDP/okdp-compiler-sandbox/commit/336f14ac8347120d5441f899fbae1f6c6b60a09f))
* updated readme to deployment scope only ([7f5be6d](https://github.com/OKDP/okdp-compiler-sandbox/commit/7f5be6d594ae0bf605af46638916e039d71a86a5))


### Bug Fixes

* **s3:** restrict the platform S3 identity to the demo project ([0c761a4](https://github.com/OKDP/okdp-compiler-sandbox/commit/0c761a45896692be877b516e04f84a14a830cb11))
* **secrets:** scope the demo's secrets to its namespace and drop kubernetes-replicator ([ae93019](https://github.com/OKDP/okdp-compiler-sandbox/commit/ae93019d229d5f35b6b456728394c6fe4b21d171))
* **tls:** verify Keycloak, OpenBao and Forgejo against the platform CA bundle ([3698e40](https://github.com/OKDP/okdp-compiler-sandbox/commit/3698e40a01a5f8008d33c7ba97f0fc2a5d382c4a))


### Code Refactoring

* **check:** let okdp-gitops compile validate the tree and fill the chart cache ([bd19062](https://github.com/OKDP/okdp-compiler-sandbox/commit/bd19062facf24a42b8c5e49942f68f4376a450f5))
