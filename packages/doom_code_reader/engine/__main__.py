"""Allow ``python3 -m engine`` to start the daemon."""

from engine.main import main

if __name__ == "__main__":
    raise SystemExit(main())
