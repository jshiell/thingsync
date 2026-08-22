"""Command line entry point."""

from __future__ import annotations

import argparse
import sys


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="thingsync",
        description="One-way mirror from Things 3 to Apple Reminders.",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor", help="check the permissions thingsync needs")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.command == "doctor":
        from thingsync.doctor import run_doctor

        lines, code = run_doctor()
        print("\n".join(lines))
        return code

    return 2


if __name__ == "__main__":
    sys.exit(main())
