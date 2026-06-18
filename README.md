# local-latex-compile

Compile LaTeX projects on Linux using Docker — no local TeX Live needed. Works with Overleaf exports, folders, and any standard LaTeX source.

## Features

- **No local LaTeX install** — compiles inside a `texlive/texlive` Docker container
- **Zip or folder input** — accepts Overleaf exports or any local project directory
- **Engine auto-detection** — detects `pdflatex`, `xelatex`, or `lualatex` from your preamble
- **Bibliography auto-detection** — picks `bibtex` or `biber` automatically
- **Makeindex / nomencl support** — detected and handled when present
- **Font handling** — mounts host fonts into the container; detects `\setmainfont` / `\setromanfont` / `\setsansfont` / `\setmonofont` commands referencing fonts not on your system and offers to substitute them with safe DejaVu defaults; re-asserts the main font after `\usepackage{lmodern}` overrides it
- **Babel compatibility** — disables active `"` shorthands for XeLaTeX/LuaLaTeX (fixes French, German, Vietnamese, Catalan, and other babel languages)
- **CRLF fix** — normalizes Windows line endings in `.tex`, `.cls`, `.sty`, `.bst` files
- **Post-compilation menu** — choose to open the PDF, open the output folder, or exit
- **Auto-cleanup** — temp directories are removed on exit (even on Ctrl+C)
- **Docker image cache** — keeps the image locally; auto-updates when a newer version exists
- **Distro-agnostic** — detects your package manager (apt, dnf, pacman, zypper) for dependency installation

## Requirements

- **Platform:** Linux (macOS works for viewing the PDF; Docker compilation also works but daemon management uses systemd/service commands)
- [Docker](https://docs.docker.com/engine/install/)
- `unzip`, `sed`, `grep`, `find` (standard on most Linux systems)

## Usage

```bash
# Run interactively (prompts for inputs)
./compile-latex.sh

# Pass input and output as positional arguments
./compile-latex.sh project.zip ./output

# Pin a specific TeX Live release
./compile-latex.sh project.zip ./output texlive/texlive:2025

# Or just the image tag — input/output will be prompted
./compile-latex.sh texlive/texlive:2025

# Show help
./compile-latex.sh --help
```

The script will guide you through:

1. **Input** — path to your `.zip` or project folder
2. **Output directory** — where to save the compiled PDF
3. **PDF filename** — name for the output file
4. **Compilation** — shows detected settings and asks for confirmation

## How it works

1. Copies or extracts your project to a temporary directory
2. Normalizes Windows line endings
3. Locates the root `.tex` file (the one with `\documentclass`)
4. Detects the LaTeX engine, bibliography tool, and indexer
5. Checks referenced fonts against host and offers DejaVu fallbacks if missing
6. Applies compatibility patches (babel shorthand, lmodern font override)
7. Runs `latexmk` inside a `texlive/texlive` Docker container
8. Copies the resulting PDF to your output directory
9. Shows a menu to open the PDF, open the folder, or exit
10. Cleans up all temporary files

## Examples

**Compile an Overleaf zip:**
```bash
./compile-latex.sh
# ? Path to .zip or folder: ~/Downloads/project.zip
```

**Compile a local project folder with a pinned TeX Live version:**
```bash
./compile-latex.sh texlive/texlive:2024
# ? Path to .zip or folder: ~/Projects/my-thesis
```

**Sample output (end of a successful run):**
```
[OK]    Compilation succeeded.
[OK]    PDF: /home/user/my-thesis/output.pdf
Next:
  [1] Open PDF (default = [Enter])
  [2] Open PDF folder
  [3] Exit
?
```

## Troubleshooting

| Problem | Likely cause |
|---|---|
| `Docker daemon unreachable` | Docker is not running. The script can start it via `systemctl` or `service`. |
| Font not found (e.g., Times New Roman) | The font is not on your system. The script detects missing fonts and offers DejaVu as a fallback. |
| Compilation fails with cryptic errors | Check the error log saved alongside the PDF. Missing packages? Try a more recent `texlive` image tag. |
| `"` quotes appear as weird characters | The script disables babel's `"` shorthand automatically. If the issue persists, check your `.tex` for other active characters. |

## License

MIT
