import os

if os.environ.get("GEARFLOW_LIVE_TESTS", os.environ.get("REPOKEEP_LIVE_TESTS")) != "1":
    from .offline import install

    install()
