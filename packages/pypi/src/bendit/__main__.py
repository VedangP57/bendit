"""Run the bundled install.sh, passing every argument through."""
import os
import sys


def main():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "install.sh")
    try:
        os.execvp("bash", ["bash", path] + sys.argv[1:])
    except FileNotFoundError:
        print("bendit needs bash, and it was not found on PATH.", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
