# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it
responsibly. **Do not open a public GitHub issue.**

Email: **[kush@redhat.com](mailto:kush@redhat.com)**

Include:

- A description of the vulnerability
- Steps to reproduce
- Any relevant logs or screenshots

You should receive an acknowledgment within 48 hours. Fixes for confirmed vulnerabilities will be released as soon as possible.

## Scope

This project produces hardened RHEL images and handles sensitive credentials
(Azure service principals, Red Hat subscriptions, SSH keys) at runtime. Security
reports related to credential handling, image hardening gaps, or supply chain
concerns in the container tooling are all in scope.

## Secrets Handling

- All credentials flow through environment variables (`.env`, never committed).
- SSH keys are generated at runtime and gitignored.
- The Podman container runs with `--cap-drop=ALL` and `--security-opt no-new-privileges`.

