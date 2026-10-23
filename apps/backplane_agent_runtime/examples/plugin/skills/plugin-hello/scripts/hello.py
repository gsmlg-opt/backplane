from pathlib import Path
print(Path(__file__).resolve().parent.parent.joinpath("references/marker.txt").read_text().strip())
