"""dvw-catalog: authoritative DevPod workspace catalog + container resolver.

Runs on the Docker host. Owns the workspace catalog and the shared
ssh-blueprint, and resolves a workspace id to its canonical container locally
(next to Docker) instead of via client-side SSH fan-out.
"""

__version__ = "0.1.0"
