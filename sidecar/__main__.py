"""Entry point for running the sidecar as a module: python -m sidecar"""

import argparse
import sys

from .server import run_server


def main():
    parser = argparse.ArgumentParser(
        description="zsh-aisuggestions sidecar daemon"
    )
    parser.add_argument(
        "-c", "--config",
        help="Path to config.yaml file",
        default=None,
    )
    args = parser.parse_args()

    run_server(config_path=args.config)


if __name__ == "__main__":
    main()
