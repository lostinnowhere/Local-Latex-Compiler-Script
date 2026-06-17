# local-latex-compile

Compile LaTeX projects on Linux using Docker — no local TeX Live needed. Works with Overleaf exports, folders, and any standard LaTeX source.

## Features

- **No local LaTeX install** — compiles inside a `texlive/texlive` Docker container
- **Zip or folder input** — accepts Overleaf exports or any local project directory
- **Engine auto-detection** — detects `pdflatex`, `xelatex`, or `lualatex` from your preamble
- **Bibliography auto-detection** — picks `bibtex` or `biber` automatically
- **Makeindex / nomencl support** — detected and handled when present
- **Font handling** — mounts host fonts into the container; re-asserts `\setmainfont` after `\usepackage{lmodern}` overrides it
- **Babel compatibility** — disables active `"` shorthands for XeLaTeX/LuaLaTeX (fixes French, German, Vietnamese, Catalan, and other babel languages)
- **CRLF fix** — normalizes Windows line endings in `.tex`, `.cls`, `.sty`, `.bst` files
- **Font fallback** — prompts to replace `Times New Roman` with a fallback if the font is not available
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

# Pin a specific TeX Live release
./compile-latex.sh texlive/texlive:2025

# Show help
./compile-latex.sh --help
```

The script will guide you through:

1. **Input** — path to your `.zip` or project folder
2. **Output directory** — where to save the compiled PDF
3. **PDF filename** — name for the output file
4. **Font fallback** — prompted only if Times New Roman is not found on your system
5. **Compilation** — shows detected settings and asks for confirmation

## How it works

1. Copies or extracts your project to a temporary directory
2. Normalizes Windows line endings
3. Locates the root `.tex` file (the one with `\documentclass`)
4. Detects the LaTeX engine, bibliography tool, and indexer
5. Applies compatibility patches (babel shorthand, font override)
6. Runs `latexmk` inside a `texlive/texlive` Docker container
7. Copies the resulting PDF to your output directory
8. Cleans up all temporary files

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

## Troubleshooting

| Problem | Likely cause |
|---|---|
| `Docker daemon unreachable` | Docker is not running. The script can start it via `systemctl` or `service`. |
| `Times New Roman` not found | The font is not installed on your host system. The script will prompt for a fallback. |
| Compilation fails with cryptic errors | Check the error log saved alongside the PDF. Missing packages? Try a more recent `texlive` image tag. |
| `"` quotes appear as weird characters | The script disables babel's `"` shorthand automatically. If the issue persists, check your `.tex` for other active characters. |

## License

MIT
