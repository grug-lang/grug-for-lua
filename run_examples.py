import subprocess
import os


def run_examples():
    for entry in os.scandir("examples"):
        lua_file = os.path.join(entry.path, "example.lua")
        print(f"--- Running {lua_file} ---")

        try:
            subprocess.run(
                ["lua", "example.lua"],
                cwd=entry.path,  # Run from within the example directory
                timeout=1,  # 1 second limit
                check=False,  # Don't raise exception on non-zero exit
            )
        except subprocess.TimeoutExpired:
            print(f"{entry.name}: Timed out after 1s.")


if __name__ == "__main__":
    run_examples()
