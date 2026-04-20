import os


def main():
    files = [f for f in os.listdir("src") if os.path.isfile(os.path.join("src", f))]

    files.sort()

    with open("grug.lua", "w", encoding="utf-8") as outfile:
        outfile.write("local grug = {}\n\n")

        for i, filename in enumerate(files):
            path = os.path.join("src", filename)

            with open(path, "r", encoding="utf-8") as infile:
                content = infile.read()

            outfile.write(f"-- BEGIN {filename}\n")
            outfile.write(content)

            outfile.write("\n")

        outfile.write("return grug\n")


if __name__ == "__main__":
    main()
