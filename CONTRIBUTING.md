# Contributing

Thanks for your interest in contributing to the Azure RHEL Image Builder pipeline.

## Prerequisites

Running the full pipeline requires paid/licensed resources that most contributors won't have locally. Before opening a PR, please make sure you understand what you can and can't test:

| Requirement | Notes |
|---|---|
| Linux host with KVM/libvirt | Fedora, RHEL, CentOS Stream, etc. |
| Podman | The pipeline runs inside a container |
| RHEL 9.x and/or 10.x DVD ISOs | Requires a Red Hat subscription or developer account |
| Red Hat subscription | Org ID + activation key for package access inside builder VMs |
| Azure service principal | Contributor role on a target resource group (phases 2–3 only) |

If you only have access to some of these, that's fine — note which phases you were able to test in your PR description.

## Development workflow

1. Fork and clone the repository.
2. Install pre-commit hooks (one-time setup):

```bash
pip install pre-commit
pre-commit install
```

3. Copy `.env.example` to `.env` and fill in your values.
4. Run the full pipeline or individual phases:

```bash
source .env
./ansible/run.sh site.yml          # full pipeline
./ansible/run.sh 01-build-images.yml   # single phase
```

5. Make your changes on a feature branch.
6. Verify that linting passes (pre-commit runs automatically on `git commit`, or manually):

```bash
pre-commit run --all-files
```

7. Open a pull request with a clear description of the change and which pipeline phases you tested.

## What to contribute

- Bug fixes and improvements to playbooks, blueprints, or kickstarts
- Support for additional RHEL versions or cloud targets
- Documentation improvements
- Linting and CI improvements

## Guidelines

- Use fully qualified collection names (FQCNs) for all Ansible modules (e.g., `ansible.builtin.command`, not `command`).
- Keep secrets out of committed files — all credentials flow through environment variables via `.env`.
- If adding a new environment variable, update both `.env.example` and `ansible/vars.yml`.
- Test with `ansible-lint` before submitting.

## Reporting issues

Open a GitHub issue. Include the RHEL version, pipeline phase, and relevant error output.
