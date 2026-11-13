"""Entry point for the standalone Linux executable."""

import multiprocessing
import os
import ssl
import sys
from pathlib import Path

from gearflow.cli import main
from gearflow.services import main as services_main

if __name__ == "__main__":
    # Must run before parsing argv: spawn workers re-enter this executable.
    multiprocessing.freeze_support()

    # System Git, Bash and ALT tools must use their own shared libraries.
    original = os.environ.get("LD_LIBRARY_PATH_ORIG")
    if original is None:
        os.environ.pop("LD_LIBRARY_PATH", None)
    else:
        os.environ["LD_LIBRARY_PATH"] = original

    # The build host's OpenSSL default paths may differ from ALT's trust store.
    if not ({"SSL_CERT_FILE", "SSL_CERT_DIR"} & os.environ.keys()):
        if ssl.get_default_verify_paths().cafile is None:
            for candidate in (
                "/etc/ssl/cert.pem",
                "/etc/ssl/certs/ca-certificates.crt",
                "/etc/pki/tls/cert.pem",
                "/var/lib/ca-certificates/ca-bundle.pem",
            ):
                if Path(candidate).is_file():
                    os.environ["SSL_CERT_FILE"] = candidate
                    break

    # The Bash workflow invokes its interpreter with this internal protocol.
    # In a frozen build sys.executable is this executable, not a Python binary.
    if sys.argv[1:3] == ["-m", "gearflow.services"]:
        raise SystemExit(services_main(sys.argv[3:]))
    raise SystemExit(main())
